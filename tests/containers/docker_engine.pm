# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

# Packages: docker
# Summary: Upstream moby e2e tests
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base 'containers::basetest', -signatures;
use testapi;
use serial_terminal qw(select_serial_terminal);
use version_utils;
use utils;
use Utils::Architectures;
use containers::bats;

my $version;
my @test_dirs;

sub setup {
    my $self = shift;
    my @pkgs = qw(containerd-ctr distribution-registry docker glibc-devel-static go1.24 make);
    $self->setup_pkgs(@pkgs);

    # The tests assume a vanilla configuration
    run_command "mv -f /etc/docker/daemon.json{,.bak}";
    run_command "mv -f /etc/sysconfig/docker{,.bak}";
    # The tests use both network & Unix socket
    run_command 'echo DOCKER_OPTS="-H 0.0.0.0:2375 -H unix:///var/run/docker.sock --insecure-registry registry:5000" > /etc/sysconfig/docker';
    # The tests assume the legacy builder
    run_command "mv /usr/lib/docker/cli-plugins/docker-buildx{,.bak}";
    run_command "systemctl enable docker";
    run_command "systemctl restart docker";
    record_info "docker info", script_output("docker info");

    # We need gotestsum to parse "go test" and create JUnit XML output
    run_command 'export GOPATH=$HOME/go';
    run_command 'export PATH=$GOPATH/bin:/usr/local/bin:$PATH';
    run_command 'go install gotest.tools/gotestsum@v1.13.0';

    # We need ping from GNU inetutils
    run_command 'docker run --rm -it -v /usr/local/bin:/target:rw,z debian sh -c "apt update; apt install -y inetutils-ping; cp -v /bin/ping* /target"', timeout => 120;
    record_info "ping version", script_output("ping --version");

    # Tests use "ctr"
    run_command "cp /usr/sbin/containerd-ctr /usr/local/bin/ctr";

    # Unprivileged user for rootless docker tests
    run_command "useradd --create-home --gid docker unprivilegeduser";

    $version = script_output "docker version --format '{{.Client.Version}}'";
    $version =~ s/-ce$//;
    $version = "v$version";

    patch_sources "moby", $version, "e2e";

    # Build test helpers
    run_command "cp -f vendor.mod go.mod || true";
    run_command "cp -f vendor.sum go.sum || true";
    run_command '(cd testutil/fixtures/plugin/basic; go mod init docker-basic-plugin; go build -o $GOPATH/bin/docker-basic-plugin)';

    # Ignore the tests in these directories in integration/
    my @ignore_dirs = (
        "network",
        "networking",
        "plugin.*",
    );
    my $ignore_dirs = join "|", map { "integration/$_" } @ignore_dirs;
    if (my $test_dirs = get_var("DOCKER_TEST_DIRS", "")) {
        @test_dirs = split(/,/, $test_dirs);
    } else {
        # Adapted from https://build.opensuse.org/projects/openSUSE:Factory/packages/docker/files/docker-integration.sh
        @test_dirs = split(/\n/, script_output(qq(go list -test -f '{{- if ne .ForTest "" -}}{{- .Dir -}}{{- end -}}' ./integration/... | sed "s,^\$(pwd)/,," | grep -vxE '($ignore_dirs)')));
        push @test_dirs, "integration-cli";
    }

    # Preload Docker images used for testing
    my $frozen_images = script_output q(grep -oE '[[:alnum:]./_-]+:[[:alnum:]._-]+@sha256:[0-9a-f]{64}' Dockerfile | xargs echo);
    run_command "contrib/download-frozen-image-v2.sh /docker-frozen-images $frozen_images", timeout => 180;

    # Tests use an older cli version for tests
    my $arch = get_var("ARCH");
    my $cliversion = script_output q(sed -n '/DOCKERCLI_INTEGRATION_VERSION=/s/.*=v//p' Dockerfile);
    run_command "curl -sSL https://download.docker.com/linux/static/stable/$arch/docker-$cliversion.tgz | tar zxvf - -C /usr/local/bin/ --strip-components 1 docker/docker";
}

sub run {
    my $self = shift;
    select_serial_terminal;
    $self->setup;
    select_serial_terminal;

    my %env = (
        TZ => "UTC",
    );
    my $env = join " ", map { "$_=\"$env{$_}\"" } sort keys %env;

    my @xfails = (
        # Flaky tests
        "github.com/docker/docker/integration/service::TestServicePlugin",
    );
    push @xfails, (
        # These tests use amd64 images:
        "github.com/docker/docker/integration/image::TestAPIImageHistoryCrossPlatform",
    ) unless (is_x86_64);

    my $tags = "apparmor selinux seccomp pkcs11";
    foreach my $dir (@test_dirs) {
        my $report = $dir =~ s|/|-|gr;
        run_command "pushd $dir";
        run_command "$env gotestsum --junitfile $report.xml --format standard-verbose ./... -- -tags '$tags' |& tee -a /var/tmp/report.txt", timeout => 1200;
        patch_junit "cli", $version, "$report.xml", @xfails;
        parse_extra_log(XUnit => "$report.xml");
        run_command "popd";
    }
    upload_logs("/var/tmp/report.txt");
}

sub cleanup() {
    script_run 'docker rm -vf $(docker ps -aq)';
    script_run 'docker rmi -f $(docker images -q)';
    script_run "docker volume prune -a -f";
    script_run "docker system prune -a -f";
    script_run "mv -f /etc/docker/daemon.json{.bak,}";
    script_run "mv -f /etc/sysconfig/docker{.bak,}";
    script_run "mv -f /usr/lib/docker/cli-plugins/docker-buildx{.bak,}";
    script_run "rm -f /root/go/bin/docker";
    systemctl "restart docker";
}

sub post_fail_hook {
    my ($self) = @_;
    cleanup;
    bats_post_hook;
}

sub post_run_hook {
    my ($self) = @_;
    cleanup;
    bats_post_hook;
}

1;

# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: umoci
# Summary: Upstream umoci integration tests
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base 'containers::basetest';
use testapi;
use serial_terminal qw(select_serial_terminal);
use containers::bats;

sub run_tests {
    my %params = @_;
    my ($rootless, $skip_tests) = ($params{rootless}, $params{skip_tests});

    return if ($skip_tests eq "all");

    my %env = (
        SOURCE_IMAGE => "/var/tmp/busybox",
        UMOCI => "/usr/bin/umoci",
    );

    my $log_file = "umoci-" . ($rootless ? "user" : "root");

    my $ret = bats_tests($log_file, \%env, $skip_tests, 1200);

    return ($ret);
}

sub run {
    my ($self) = @_;
    select_serial_terminal;

    my @pkgs = qw(attr diffutils file go1.24 jq libcap-progs make moreutils python313-xattr runc skopeo umoci);
    $self->setup_pkgs(@pkgs);

    run_command 'export GOPATH=$HOME/go';
    run_command 'go install github.com/vbatts/go-mtree/cmd/gomtree@v0.6.0';
    run_command 'cp $HOME/go/bin/gomtree /usr/local/bin/';
    run_command 'skopeo copy docker://registry.opensuse.org/opensuse/busybox oci:/var/tmp/busybox';
    # https://github.com/opencontainers/umoci/blob/main/Dockerfile
    run_command 'git clone -b v0.5.0 https://github.com/opencontainers/runtime-tools.git /tmp/oci-runtime-tools';
    run_command '(cd /tmp/oci-runtime-tools && go mod init github.com/opencontainers/runtime-tools && go mod tidy && go get github.com/opencontainers/runtime-spec@v1.0.2 && go mod vendor)';
    run_command 'make -C /tmp/oci-runtime-tools tool install';

    my $umoci_version = script_output("umoci --version | awk '{ print \$3 }'");
    $umoci_version = "v$umoci_version";
    record_info("umoci version", $umoci_version);

    switch_to_user;

    patch_sources "umoci", $umoci_version, "test";
    run_command 'git submodule update --init hack/docker-meta-scripts';

    my $errors = run_tests(rootless => 1, skip_tests => get_var('BATS_SKIP_USER', ''));

    switch_to_root;

    $errors += run_tests(rootless => 0, skip_tests => get_var('BATS_SKIP_ROOT', ''));

    die "umoci tests failed" if ($errors);
}

sub post_fail_hook {
    bats_post_hook;
}

sub post_run_hook {
    bats_post_hook;
}

1;

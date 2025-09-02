# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

# Packages: python3-docker & python3-podman
# Summary: Test podman & docker python packages
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base 'containers::basetest', -signatures;
use testapi;
use serial_terminal qw(select_serial_terminal);
use version_utils;
use utils;
use XML::LibXML;
use containers::common qw(install_packages);
use containers::bats;

my $oci_runtime;

# mapping of known expected failures
my %xfails = (
    '[It] Podman run with volumes podman run with --mount and named volume with driver-opts' => {
        bug => 'bsc#1249050 - podman passes volume options as bind mount options to runtime',
        runtimes => ['runc'],
    },
    '[It] Podman run with volumes podman named volume copyup' => {
        bug => 'bsc#1249050 - podman passes volume options as bind mount options to runtime',
        runtimes => ['runc'],
    },
);

sub patch_junit_xfails {
    my ($xmlfile, $runtime) = @_;
    my $xml = script_output("cat $xmlfile");
    my $parser = XML::LibXML->new;
    my $doc = $parser->parse_string($xml);

    my $patched = 0;

    # Loop over all testcases in the DOM
    for my $testcase ($doc->findnodes('//testcase')) {
        my $name = $testcase->getAttribute('name');
        # Skip if there's no soft-fail defined
        next unless exists $xfails{$name};

        my $rule = $xfails{$name};
        # Skip if not applicable to this runtime
        next unless grep { $_ eq $runtime } @{$rule->{runtimes}};
        my $reference = $rule->{bug};

        # Patch failures to skipped
        my @failures = $testcase->findnodes('./failure');
        if (@failures) {
            for my $failure_node ($testcase->findnodes('./failure')) {
                $testcase->removeChild($failure_node);
                $testcase->removeAttribute('status');
                $testcase->setAttribute('status', 'skipped');
                $testcase->appendTextChild('skipped', "Softfailed: $rule->{bug}");
                record_info("XFAIL", $reference);

                # Adjust parent <testsuite> counters
                if (my $suite = $testcase->parentNode) {
                    my $fail = $suite->getAttribute('failures');
                    my $skip = $suite->getAttribute('skipped');
                    $suite->setAttribute('failures', $fail - 1);
                    $suite->setAttribute('skipped', $skip + 1);
                }

                $patched++;
                last;
            }
        } else {
            record_info("PASS", $name);
        }
    }

    # Adjust root <testsuites> counters
    if ($patched) {
        if (my ($suites) = $doc->findnodes('/testsuites')) {
            my $failures = $suites->getAttribute('failures');
            my $skipped = $suites->getAttribute('skipped');
            $suites->setAttribute('failures', $failures - $patched);
            $suites->setAttribute('skipped', $skipped + $patched);
        }
    }

    # Write patched XML back
    write_sut_file $xmlfile, $doc->toString(1);
}

sub setup {
    my @pkgs = qw(aardvark-dns apache2-utils buildah catatonit glibc-devel-static go1.24 gpg2 jq libgpgme-devel
      libseccomp-devel make netavark openssl podman podman-remote skopeo socat sudo systemd-container xfsprogs);
    push @pkgs, qw(criu libcriu2) if is_tumbleweed;
    $oci_runtime = get_var("OCI_RUNTIME", "runc");
    push @pkgs, $oci_runtime;

    install_packages(@pkgs);
    install_git;

    record_info "info", script_output("podman info -f json");

    # Workaround for https://bugzilla.opensuse.org/show_bug.cgi?id=1248988 - catatonit missing in /usr/libexec/podman/
    run_command "cp -f /usr/bin/catatonit /usr/libexec/podman/catatonit";
    # rootless user needed for these tests
    run_command "useradd -m containers";
    run_command "usermod --add-subuids 100000-165535 containers";
    run_command "usermod --add-subgids 100000-165535 containers";
    # Make /run/secrets directory available on containers
    run_command "echo /var/lib/empty:/run/secrets >> /etc/containers/mounts.conf";

    # Enable SSH
    my $algo = "ed25519";
    systemctl 'enable --now sshd';
    run_command "ssh-keygen -t $algo -N '' -f ~/.ssh/id_$algo";
    run_command "cat ~/.ssh/id_$algo.pub >> ~/.ssh/authorized_keys";
    run_command "ssh-keyscan localhost 127.0.0.1 ::1 | tee -a ~/.ssh/known_hosts";

    # Download podman sources
    my $version = script_output q(podman --version | awk '{ print $3 }');
    record_info "version", $version;
    my $github_org = "containers";
    my $branch = "v$version";

    # Support these cases for GIT_REPO: [<GITHUB_ORG>]#BRANCH
    # 1. As GITHUB_ORG#TAG: github_user#test-patch
    # 2. As TAG only: main, v1.2.3, etc
    # 3. Empty. Use defaults specified above for $github_org & $branch
    my $repo = get_var("GIT_REPO", "");
    if ($repo =~ /#/) {
        ($github_org, $branch) = split("#", $repo, 2);
    } elsif ($repo) {
        $branch = $repo;
    }

    run_command "cd ~";
    run_command "git clone --branch $branch https://github.com/$github_org/podman", timeout => 300;
    run_command "cd ~/podman";

    unless ($repo) {
        # - https://github.com/containers/podman/pull/25942 - Fix: Remove appending rw as the default mount option
        # - https://github.com/containers/podman/pull/26934 - test/e2e: fix 'block all syscalls' seccomp for runc
        # - https://github.com/containers/podman/pull/26936 - Skip some tests that fail on runc
        my @patches = is_sle ? qw(25942 26934) : qw(26934);
        foreach my $patch (@patches) {
            my $url = "https://github.com/$github_org/podman/pull/$patch";
            record_info("patch", $url);
            assert_script_run "curl -O " . data_url("containers/patches/podman/$patch.patch");
            run_command "git apply -3 --ours $patch.patch";
        }
        # This test fails with:
        # Command exited 125 as expected, but did not emit 'failed to connect: dial tcp: lookup '
        run_command "rm -f test/e2e/image_scp_test.go";
    }
}

sub run {
    my ($self, $args) = @_;
    select_serial_terminal;

    setup;

    my $quadlet = script_output "rpm -ql podman | grep podman/quadlet";

    my %env = (
        OCI_RUNTIME => $oci_runtime,
        PODMAN_BINARY => "/usr/bin/podman",
        PODMAN_REMOTE_BINARY => "/usr/bin/podman-remote",
        QUADLET_BINARY => "/usr/libexec/podman/quadlet",
        TESTFLAGS => "--junit-report=report.xml",
    );
    my $env = join " ", map { "$_=$env{$_}" } sort keys %env;

    my $default_targets = "localintegration";
    $default_targets .= " remoteintegration" if is_tumbleweed;
    my @targets = split('\s+', get_var('PODMAN_TARGETS', $default_targets));
    foreach my $target (@targets) {
        run_command "env $env make $target |& tee $target.txt || true", timeout => 1800;
        script_run qq{sed -ri '0,/name=/s/name="Libpod Suite"/name="$target"/' report.xml};
        script_run "cp report.xml /tmp/$target.xml";
        patch_junit_xfails("/tmp/$target.xml", $oci_runtime);
        parse_extra_log(XUnit => "/tmp/$target.xml");
        upload_logs("$target.txt");
    }
}

sub post_fail_hook {
    bats_post_hook;
}

sub post_run_hook {
    bats_post_hook;
}

1;

# SUSE's openQA tests
#
# Copyright 2024-2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: umoci
# Summary: Upstream umoci integration tests
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base 'containers::basetest';
use testapi;
use serial_terminal qw(select_serial_terminal);
use utils qw(script_retry);
use containers::common;
use Utils::Architectures qw(is_x86_64);
use containers::bats;
use version_utils qw(is_sle);

my $test_dir = "/var/tmp/umoci-tests";

sub run_tests {
    my %params = @_;
    my ($rootless, $skip_tests) = ($params{rootless}, $params{skip_tests});

    return if ($skip_tests eq "all");

    my $log_file = "umoci-" . ($rootless ? "user" : "root") . ".tap";

    my $tmp_dir = script_output "mktemp -d -p /var/tmp test.XXXXXX";

    my %_env = (
        BATS_TMPDIR => $tmp_dir,
        UMOCI => "/usr/bin/umoci",
        PATH => '/usr/local/bin:$PATH:/usr/sbin:/sbin',
    );
    my $env = join " ", map { "$_=$_env{$_}" } sort keys %_env;

    assert_script_run "echo $log_file .. > $log_file";

    my @tests;
    foreach my $test (split(/\s+/, get_var("BATS_TESTS", ""))) {
        $test .= ".bats" unless $test =~ /\.bats$/;
        push @tests, "test/$test";
    }
    my $tests = @tests ? join(" ", @tests) : "test";

    my $ret = script_run "env $env bats --tap $tests | tee -a $log_file", 1200;

    unless (@tests) {
        my @skip_tests = split(/\s+/, get_var('BATS_SKIP', '') . " " . $skip_tests);
        patch_logfile($log_file, @skip_tests);
    }

    parse_extra_log(TAP => $log_file);

    script_run "rm -rf $tmp_dir";

    return ($ret);
}

sub run {
    my ($self) = @_;
    select_serial_terminal;

    my @pkgs = qw(go-mtree jq python3-xattr runc umoci);

    zypper_call "ar -f -p 10 -g 'obs://home:cyphar:containers/\$releasever' obs-gomtree";
    zypper_call "--gpg-auto-import-keys ref";

    $self->bats_setup(@pkgs);

    record_info("umoci version", script_output("umoci --version"));
    record_info("umoci package version", script_output("rpm -q umoci"));

    # Download umoci sources
    my $umoci_version = script_output "umoci --version  | awk '{ print \$3 }'";
    my $url = get_var("BATS_URL", "https://github.com/opencontainers/umoci/archive/refs/tags/v$umoci_version.tar.gz");
    assert_script_run "mkdir -p $test_dir";
    assert_script_run "cd $test_dir";
    script_retry("curl -sL $url | tar -zxf - --strip-components 1", retry => 5, delay => 60, timeout => 300);

    my $errors = run_tests(rootless => 1, skip_tests => get_var('BATS_SKIP_USER', ''));

    select_serial_terminal;
    assert_script_run "cd $test_dir";

    $errors += run_tests(rootless => 0, skip_tests => get_var('BATS_SKIP_ROOT', ''));

    die "umoci tests failed" if ($errors);
}

sub post_fail_hook {
    bats_post_hook $test_dir;
}

sub post_run_hook {
    bats_post_hook $test_dir;
}

1;

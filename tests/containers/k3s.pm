# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

# Packages: k3s
# Summary: Upstream k3s tests
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base 'containers::basetest', -signatures;
use testapi;
use serial_terminal qw(select_serial_terminal);
use version_utils;
use version;
use utils;
use Utils::Architectures;
use containers::bats;

my $version;

sub setup {
    my $self = shift;
    my @pkgs = qw(container-selinux go1.26 iptables);
    push @pkgs, "k3s-selinux" unless is_sle;
    $self->setup_pkgs(@pkgs);
    install_gotestsum;

    run_command "curl -sfL https://get.k3s.io | sh -";
    run_command 'systemctl disable --now firewalld';
    run_command 'systemctl disable --now k3s';

    $version = script_output q(k3s --version | awk '{ print $3; exit }');
    record_info "k3s version", $version;

    patch_sources "k3s", $version, "tests/integration";
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

    my @xfails = ();

    run_timeout_command "$env gotestsum --junitfile integration.xml --format standard-verbose ./tests/integration/... -ldflags='-X github.com/k3s-io/k3s/tests/integration.existingServer=True' -- -v -args -ginkgo.v &> integration.txt", no_assert => 1, timeout => 3000;
    upload_logs "integration.txt";
    die "Testsuite failed" if script_run("test -s integration.xml");
    patch_junit "k3s", $version, "integration.xml", @xfails;
    parse_extra_log(XUnit => "integration.xml", timeout => 180);

}

sub post_fail_hook {
    bats_post_hook;
}

sub post_run_hook {
    bats_post_hook;
}

1;

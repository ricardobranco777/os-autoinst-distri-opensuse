# SUSE's openQA tests
#
# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: isolation
# Summary: Test container network isolation
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base 'containers::basetest';
use testapi;
use serial_terminal qw(select_serial_terminal select_user_serial_terminal);
use containers::common qw(install_packages);
use utils qw(script_retry);

my $runtime;
my $network_base = "test_internal_net";

sub run_tests {
    my $ip_version = shift;

    my $network = "$network_base-$ip_version";
    my $opts = $ip_version == 6 ? "--ipv6" : "";
    assert_script_run "$runtime network create $opts --internal $network";

    my $iface = script_output "ip -$ip_version --json route list match default | jq -r '.[0].dev'";
    my $ip_addr = script_output "ip -$ip_version --json addr show $iface | jq -r '.[0].addr_info[0].local'";

    # We use alpine as registry.opensuse.org/opensuse/busybox has a buggy ping that needs setuid root
    my $image = "alpine";
    script_retry("$runtime pull $image", timeout => 300, delay => 60, retry => 3);

    # Test that containers can't access the host
    assert_script_run "! $runtime run --rm --network $network $image ping -$ip_version -c 3 $ip_addr";

    # Test that containers can't access the Internet
    my $aaaa = $ip_version == 6 ? "AAAA" : "A";
    my $external_ip = script_output "dig +short $aaaa www.opensuse.org | tail -n1";
    assert_script_run "! $runtime run --rm --network $network $image ping -$ip_version -c 3 $external_ip";

    # Test that containers can't modify IP routes
    assert_script_run "! $runtime run --rm --network $network $image ip -$ip_version route add default via $ip_addr";

    assert_script_run "$runtime network rm $network";
}

sub run {
    my ($self, $args) = @_;

    select_serial_terminal;

    $runtime = $self->containers_factory($args->{runtime});
    install_packages('jq');

    run_tests 4;
    run_tests 6;

    return if ($args->{runtime} eq "docker");
    select_user_serial_terminal;

    run_tests 4;
    run_tests 6;

    select_serial_terminal;
}

1;

sub cleanup() {
    if ($runtime->{runtime} ne "docker") {
        select_user_serial_terminal;
        script_run "$runtime network rm $network_base-4 $network_base-6";
        $runtime->cleanup_system_host();
    }

    select_serial_terminal;
    script_run "$runtime network rm $network_base-4 $network_base-6";
    $runtime->cleanup_system_host();
}

sub post_fail_hook {
    my ($self) = @_;
    cleanup;
    $self->SUPER::post_fail_hook;
}

sub post_run_hook {
    my ($self) = @_;
    cleanup;
    $self->SUPER::post_run_hook;
}

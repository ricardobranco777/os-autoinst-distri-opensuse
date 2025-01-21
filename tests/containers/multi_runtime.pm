# SUSE's openQA tests
#
# Copyright 2024-2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Validate docker and podman network interoperability
# - validate if podman and docker networking works together
# - check if firewalld doesn't break either
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base qw(containers::basetest);
use testapi;
use serial_terminal qw(select_serial_terminal select_user_serial_terminal);
use utils;
use containers::common qw(install_packages);
use Utils::Logging 'save_and_upload_log';

my @containers;
my $test_image = "registry.opensuse.org/opensuse/nginx";

sub run_tests {
    my $test_url = "http://www.opensuse.org";
    my $volumes = '-v $HOME/nginx/nginx.conf:/etc/nginx/nginx.conf:ro,z -v $HOME/nginx:/usr/share/nginx/html:ro,z';
    my $curl_opts = "-svL -o /dev/null";
    my $port = 8000;

    # Create rootfull & rootless containers on both podman & docker
    for my $runtime ("podman", "docker") {
        for my $type ("root", "rootless") {
            my $name = "test_${type}_${runtime}";
            my $sudo = ($type eq "root") ? "sudo" : "";
            script_retry("$sudo $runtime pull $test_image", retry => 3, delay => 60, timeout => 180);
            assert_script_run "$sudo $runtime run -d --name $name -p $port:80 $volumes $test_image";
            push @containers, {name => $name, runtime => $runtime, sudo => $sudo, port => $port};
            $port++;
        }
    }

    # Test connectivity to all containers on localhost
    for my $container (@containers) {
        assert_script_run "curl -4 $curl_opts http://127.0.0.1:$container->{port}",
          fail_message => "failed IPv4 localhost test for $container->{name}";
    }

    # Test container connectivity to the outside world
    for my $container (@containers) {
        assert_script_run "$container->{sudo} $container->{runtime} exec $container->{name} curl -4 $curl_opts $test_url",
          fail_message => "failed IPv4 Internet test for $container->{name}";
    }
}

sub run {
    select_serial_terminal;

    my @pkgs = ("docker", "podman");
    install_packages(@pkgs);

    systemctl "enable --now docker";

    record_info("docker root", script_output("docker info"));
    record_info("podman root", script_output("podman info"));

    # Needed to avoid:
    # WARNING: COMMAND_FAILED: '/sbin/iptables -t nat -F DOCKER' failed: iptables: No chain/target/match by that name.
    # See https://bugzilla.suse.com/show_bug.cgi?id=1196801
    systemctl "restart firewalld";
    systemctl "status firewalld";

    assert_script_run "echo '$testapi::username ALL=(ALL:ALL) NOPASSWD: ALL' | tee -a /etc/sudoers.d/nopasswd";

    # Running podman as root with docker installed may be problematic as netavark uses nftables
    # while docker still uses iptables.
    # Use workaround suggested in:
    # - https://fedoraproject.org/wiki/Changes/NetavarkNftablesDefault#Known_Issue_with_docker
    # - https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-on-a-router
    script_run "iptables -I DOCKER-USER -j ACCEPT";

    select_user_serial_terminal;

    # https://docs.docker.com/engine/security/rootless/
    assert_script_run "dockerd-rootless-setuptool.sh install";
    systemctl "--user enable --now docker";

    record_info("docker rootless", script_output("docker info"));
    record_info("podman rootless", script_output("podman info"));

    assert_script_run "mkdir -m 755 nginx";
    assert_script_run('curl -sLf -vo $HOME/nginx/nginx.conf ' . data_url('containers/nginx/') . 'nginx.conf');
    assert_script_run('curl -sLf -vo $HOME/nginx/index.html ' . data_url('containers/nginx/') . 'index.html');
    assert_script_run "chmod 644 nginx/*";

    run_tests;
}

sub cleanup {
    for my $container (@containers) {
        script_run "$container->{sudo} $container->{runtime} rm -vf $container->{name}";
        script_run "$container->{sudo} $container->{runtime} rmi $test_image";
    }
}

sub post_run_hook {
    cleanup;
}

sub post_fail_hook {
    save_and_upload_log("sudo ss -tnlp", "/tmp/tcp_services.txt");
    save_and_upload_log("ip -4 addr", "/tmp/ip4addr.txt");
    save_and_upload_log("ip -4 route", "/tmp/ip4route.txt");
    save_and_upload_log("sudo nft list ruleset", "/tmp/nft.txt");

    for my $container (@containers) {
        script_run "$container->{sudo} $container->{runtime} logs $container->{name}";
        script_run "$container->{sudo} $container->{runtime} inspect $container->{name}";
    }
    cleanup;
}

1;

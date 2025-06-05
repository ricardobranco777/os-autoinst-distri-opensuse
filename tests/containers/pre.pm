# SUSE's openQA tests
#
# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Module for all hacks previous to all container tests
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base 'containers::basetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use utils;
use version_utils;

sub get_user_subuid {
    my ($user) = shift;
    my $start_range = script_output("awk -F':' '\$1 == \"$user\" {print \$2}' /etc/subuid",
        proceed_on_failure => 1);
    return $start_range;
}

sub run {
    my ($self) = @_;
    select_serial_terminal;
    my $user = $testapi::username;

    # add testuser to systemd-journal group to allow non-root
    # user to access container logs via journald event driver
    # bsc#1207673, bsc#1218023
    assert_script_run("usermod -aG systemd-journal $user") if (is_leap("<16") || is_sle("<16"));

    # Some products don't have bernhard pre-defined (e.g. SLE Micro)
    if (script_run("grep $user /etc/passwd") != 0) {
        assert_script_run "useradd -m $user";
        assert_script_run "echo '$user:$testapi::password' | chpasswd";
        # Make sure user has access to tty group
        my $serial_group = script_output "stat -c %G /dev/$testapi::serialdev";
        assert_script_run "grep '^${serial_group}:.*:${user}\$' /etc/group || (chown $user /dev/$testapi::serialdev && gpasswd -a $user $serial_group)";
    }

    # NOTE: Drop when SLES 15-SP3 is EOL
    # Up to SLES 15-SP3, YaST doesn't set up subuid's & subgid's
    if (is_sle('<15-SP4')) {
        my $subuid_start = get_user_subuid($user);
        if ($subuid_start eq '') {
            $subuid_start = 200000;
            my $subuid_range = $subuid_start + 65535;
            assert_script_run "usermod --add-subuids $subuid_start-$subuid_range --add-subgids $subuid_start-$subuid_range $user";
        }
    }
    assert_script_run "grep $user /etc/subuid", fail_message => "subuid range not assigned for $user";
    assert_script_run "grep $user /etc/subgid", fail_message => "subgid range not assigned for $user";
    assert_script_run "setfacl -m u:$user:r /etc/zypp/credentials.d/*" if is_sle;
}

1;

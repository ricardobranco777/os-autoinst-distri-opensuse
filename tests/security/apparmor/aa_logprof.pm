# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Package: audit nscd apparmor-utils
# Summary: Test the utility for updating AppArmor security profiles.
# - Stops nscd and restarts auditd
# - Create a temporary profile dir on /tmp
# - Remove '/usr.*nscd mrix' and 'nscd\.conf' from /tmp/apparmor.d/usr.sbin.nscd
# - Run "aa-complain -d /tmp/apparmor.d usr.sbin.nscd" check for "setting
# complain"
# - Start nscd, upload logfiles
# - Run "aa-logprof -d /tmp/apparmor.d" interactivelly
# - Check /tmp/apparmor.d/usr.sbin.nscd" for '/usr.*nscd mrix' and 'nscd\.conf'
# - Check if nscd could start with the temporary apparmor profiles
# - Cleanup temporary directory
# Maintainer: QE Security <none@suse.de>
# Tags: poo#36892, poo#45803, poo#81730, tc#1767574

use base "apparmortest";
use strict;
use warnings;
use testapi;
use utils;
use version_utils qw(is_tumbleweed is_sle is_leap);
use serial_terminal qw(select_serial_terminal);

sub run {
    my ($self) = @_;
    my $log_file = $apparmortest::audit_log;
    my $output;
    my $aa_tmp_prof = "/tmp/apparmor.d";
    my $audit_service = is_tumbleweed ? 'audit-rules' : 'auditd';
    my $interactive_str = [
        {
            prompt => qr/\(A\)llow/m,
            key => 'a',
        },
        {
            prompt => qr/\(S\)ave Changes/m,
            key => 's',
        },
    ];

    # Stop nscd and restart auditd before generate needed audit logs
    systemctl('stop nscd');
    systemctl("restart $audit_service");

    $self->aa_tmp_prof_prepare("$aa_tmp_prof", 1);

    my @aa_logprof_items = ('\/usr.*\/nscd mrix', 'nscd\.conf r');

    # Remove some rules from profile
    foreach my $item (@aa_logprof_items) {
        assert_script_run "sed -i '/$item/d' $aa_tmp_prof/usr.sbin.nscd";
    }

    validate_script_output "aa-complain -d $aa_tmp_prof usr.sbin.nscd", sub { m/Setting.*complain/ };

    assert_script_run "echo > $log_file";

    systemctl('start nscd');

    assert_script_run "aa-status | tee /dev/$serialdev";

    # Upload audit.log for reference
    upload_logs "$log_file";

    select_console 'root-console';
    script_run_interactive("aa-logprof -d $aa_tmp_prof", $interactive_str, 30);
    select_serial_terminal;

    foreach my $item (@aa_logprof_items) {
        validate_script_output "cat $aa_tmp_prof/usr.sbin.nscd", sub { m/$item/ };
    }

    $self->aa_tmp_prof_verify("$aa_tmp_prof", 'nscd');
    $self->aa_tmp_prof_clean("$aa_tmp_prof");

    if (!is_sle("<15-sp3") && !is_leap("<15.3")) {
        # Verify "https://bugs.launchpad.net/apparmor/+bug/1848227"
        $self->test_profile_content_is_special("aa-logprof -f", "Reading log entries.*");

        # Verify "aa-logprof" can work with "log message contains a filename with unbalanced parenthesis"
        my $testfile = "/usr/bin/ls";
        my $test_special = '/usr/bin/l\(s';
        $self->create_log_content_is_special("$testfile", "$test_special");
        select_console 'root-console';
        script_run_interactive("aa-logprof -f $log_file", $interactive_str, 30);
        select_serial_terminal;

        # Verify "https://bugs.launchpad.net/apparmor/+bug/1848227"
        $self->test_profile_content_is_special("aa-logprof", "Reading log entries from.*");
    }
}

1;

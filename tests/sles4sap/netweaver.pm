# SUSE's SLES4SAP openQA tests
#
# Copyright (C) 2019 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Install NetWeaver with SAP Installation Wizard
# Maintainer: Ricardo Branco <rbranco@suse.de>

use base 'sles4sap';
use strict;
use testapi;
use utils qw(type_string_slow zypper_call);
use version_utils 'is_sle';
use x11utils 'turn_off_gnome_screensaver';

sub run {
    my ($self) = @_;
    my ($proto, $path) = split m|://|, get_required_var('MEDIA');
    die "Currently supported protocols are nfs and smb" unless $proto =~ /^(nfs|smb)$/;
    # Don't change this. The needle has this SID.
    my $sid      = 'NDB';
    my $password = 'Qwerty_123';
    set_var('PASSWORD', $password);
    set_var('SAPADM',   lc($sid) . 'adm');

    # Add host's IP to /etc/hosts
    select_console 'root-console';
    assert_script_run 'echo $(ip -4 addr show dev eth0 | sed -rne "/inet/s/[[:blank:]]*inet ([0-9\.]*).*/\1/p") $(hostname).local $(hostname) >> /etc/hosts';
    if (is_sle('>=15')) {
        my $arch       = get_required_var('ARCH');
        my $os_version = script_output('sed -rn "s/^VERSION_ID=\"(.*)\"/\1/p" /etc/os-release');
        assert_script_run "SUSEConnect -p sle-module-legacy/$os_version/$arch";
        zypper_call('in libopenssl1_0_0');
    }
    # Installation scripts use netstat
    zypper_call('in net-tools-deprecated');
    # Resize root filesystem
    assert_script_run 'lvextend -l +$(pvdisplay | sed -rne "/Free PE/s/.* ([0-9]+)$/\1/p") /dev/system/root ; btrfs filesystem resize max /; df -h';
    select_console 'x11';
    mouse_hide;

    x11_start_program('xterm');
    turn_off_gnome_screensaver;
    type_string "killall xterm\n";
    assert_screen 'generic-desktop';
    x11_start_program('yast2 sap-installation-wizard', target_match => 'sap-installation-wizard');
    send_key 'tab';
    send_key_until_needlematch 'sap-wizard-proto-' . $proto . '-selected', 'down';
    send_key 'alt-p';
    type_string_slow "$path", wait_still_screen => 1;
    save_screenshot;
    send_key 'tab';
    send_key $cmd{next};
    assert_screen 'sap-wizard-copying-media';
    assert_screen 'sap-wizard-installation-medium', 3000;
    if (0) {
    send_key 'alt-p';
    type_string_slow "nfs://saphq.suse.de:/Public/NW75/x86_64/sap_kernel";
    }
    send_key $cmd{next};
    assert_screen 'sap-wizard-more-product-mediums', 3000;
    if (0) {
    send_key 'alt-y';
    assert_screen 'sap-wizard-installation-medium', 200;
    send_key 'alt-p';
    type_string_slow "nfs://saphq.suse.de:/Public/NW752";
    }
    send_key $cmd{next};
    assert_screen 'sap-wizard-installation-type', 60;
    save_screenshot;
    # SAP Standalone Engines
    send_key 'alt-l';
    save_screenshot;
    send_key $cmd{next};
    assert_screen 'sap-wizard-choose-product', 500;
    #assert_and_dclick 'sap-wizard-choose-product-gw-sap-nw75', timeout => 500;
    send_key 'down';
    send_key 'down';
    send_key 'down';
    send_key 'down';
    send_key 'down';
    save_screenshot;
    send_key $cmd{next};
    assert_screen 'sap-wizard-supplement-medium';
    send_key $cmd{next};
    assert_screen 'sap-wizard-additional-repos';
    send_key $cmd{next};
    if (0) {
    assert_screen 'sap-wizard-system-parameters', 60;
    # SAP SID / Password
    send_key 'alt-s';
    type_string $sid;
    wait_screen_change { send_key 'alt-a' };
    type_password $password;
    wait_screen_change { send_key 'tab' };
    type_password $password;
    wait_screen_change { send_key $cmd{ok} };
    }
    #assert_screen 'sap-wizard-performing-installation', 60;
    assert_screen 'sap-wizard-profile-ready', 200;
    send_key $cmd{next};
    assert_screen 'sap-product-installation';
    assert_screen [qw(sap-wizard-installation-summary sap-wizard-finished sap-wizard-failed sap-wizard-error sap-wizard-crashed)], 4000;
    send_key $cmd{ok};
    if (match_has_tag 'sap-wizard-installation-summary') {
        assert_screen 'generic-desktop', 600;
    } else {
        assert_screen 'sap-wizard-finished'; 
        send_key $cmd{ok};
        # Wait for SAP wizard to finish writing logs
        check_screen 'generic-desktop', 90;
        die "Failed";
    }
    assert_script_run "dh -h";
}

sub test_flags {
    return {fatal => 1};
}

sub post_fail_hook {
    my ($self) = @_;
    select_console 'root-console';

    assert_script_run 'tar cf /tmp/logs.tar /var/adm/autoinstall/logs; xz -9v /tmp/logs.tar';
    upload_logs '/tmp/logs.tar.xz';
    assert_script_run "save_y2logs /tmp/y2logs.tar.xz";
    upload_logs "/tmp/y2logs.tar.xz";
    $self->SUPER::post_fail_hook;
}

1;

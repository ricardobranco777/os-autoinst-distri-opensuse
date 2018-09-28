# SUSE's SLES4SAP openQA tests
#
# Copyright (C) 2018 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

# Summary: Checks HANA Wizard installation on Gnome
# Requires: ENV variable MEDIA pointing to installation media, QEMURAM=32768
# Maintainer: Ricardo Branco <rbranco@suse.de>

use base 'basetest';
use strict;
use testapi;
use utils 'turn_off_gnome_screensaver';
use utils 'type_string_slow';

sub run {
    my ($self) = @_;
    my ($proto, $path) = split m|://|, get_required_var('MEDIA');

    die "Currently supported protocols are nfs and smb"
      unless ($proto eq 'nfs' or $proto eq 'smb');

    my $QEMURAM = get_required_var('QEMURAM');
    die "QEMURAM=$QEMURAM. QEMURAM must be at least 32768" if $QEMURAM < 32768;

    # Add host's IP to /etc/hosts
    select_console 'root-console';
    # Resize root filesystem
    assert_script_run 'lvextend -l +$(pvdisplay | sed -rne "/Free PE/s/.* ([0-9]+)$/\1/p") /dev/system/root ; btrfs filesystem resize max /';
    assert_script_run 'echo $(ip -4 addr show dev eth0 | sed -rne "/inet/s/[[:blank:]]*inet ([0-9\.]*).*/\1/p") $(hostname) >> /etc/hosts';
    select_console 'x11', await_console => 0;

    x11_start_program('xterm -geometry 160x45+5+5', target_match => 'xterm-susetest');
    turn_off_gnome_screensaver;
    save_screenshot;
    type_string "killall xterm\n";

    assert_screen 'generic-desktop';
    x11_start_program 'yast2 sap-installation-wizard';
    assert_screen 'sap-installation-wizard';
    save_screenshot;

    # Choose nfs://
    send_key 'tab';
    send_key_until_needlematch 'sap-wizard-proto-' . $proto . '-selected', 'down';
    send_key 'alt-p';
    type_string_slow "$path", wait_still_screen => 1;
    # Next
    send_key 'tab';
    send_key 'alt-n';
    save_screenshot;

    assert_screen 'sap-wizard-copying-media';
    save_screenshot;

    # "Do you use a Supplement/3rd-Party SAP software medium?"
    assert_screen 'sap-wizard-supplement-medium', 3000;
    save_screenshot;
    # No
    send_key 'alt-n';
    save_screenshot;
    assert_screen 'sap-wizard-additional-repos';
    save_screenshot;
    # Next
    send_key 'alt-n';

    # Don't change this. The needle has this SID.
    my $sid = 'NDB';

    assert_screen 'sap-wizard-hana-system-parameters';
    # SAP SID
    send_key 'alt-s';
    type_string $sid;
    # SAP Master Password
    send_key 'alt-a';
    type_password 'Qwerty_123';
    send_key 'tab';
    type_password 'Qwerty_123';
    save_screenshot;
    # Ok
    send_key 'alt-o';

    set_var('SAPADM', lc($sid) . 'adm');

    assert_screen 'sap-wizard-performing-installation', 60;
    save_screenshot;

    # "Are there more SAP products to be prepared for installation?"
    assert_screen 'sap-wizard-profile-ready', 300;
    save_screenshot;
    # No
    send_key 'alt-n';
    save_screenshot;

    # "Do you want to continue the installation?"
    # "Your system does not meet the requirements..."
    assert_screen 'sap-wizard-continue-installation';
    save_screenshot;
    # Yes
    send_key 'alt-y';
    save_screenshot;

    assert_screen 'sap-product-installation';

    assert_screen [qw(sap-wizard-installation-summary sap-wizard-finished sap-wizard-failed sap-wizard-error)], 4000;
    save_screenshot;
    if (match_has_tag 'sap-wizard-installation-summary') {
        send_key 'alt-o';
        save_screenshot;
        assert_screen 'generic-desktop', 600;
    } else {
        if (match_has_tag 'sap-wizard-error') {
            send_key 'alt-o';
        } elsif (match_has_tag 'sap-wizard-failed') {
            send_key 'tab';
            save_screenshot;
            send_key 'ret';
        }
        save_screenshot;
        assert_screen 'generic-desktop', 120;
        select_console 'root-console';
        assert_script_run 'tar cf /tmp/logs.tar /var/adm/autoinstall/logs; xz -9v /tmp/logs.tar';
        upload_logs '/tmp/logs.tar.xz';
        die "Failed";
    }
}

sub test_flags {
    # 'fatal'          - abort whole test suite if this fails (and set overall state 'failed')
    # 'ignore_failure' - if this module fails, it will not affect the overall result at all
    # 'milestone'      - after this test succeeds, update 'lastgood'
    # 'norollback'     - don't roll back to 'lastgood' snapshot if this fails
    return {fatal => 1};
}

1;

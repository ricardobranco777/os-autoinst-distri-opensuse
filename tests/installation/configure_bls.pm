# SUSE's openQA tests
#
# Copyright 2023 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Select systemd-boot in the installer
# Maintainer: Fabian Vogt <fvogt@suse.com>

use strict;
use warnings;
use base 'y2_installbase';
use testapi;
use utils;
use version_utils qw(is_bootloader_sdboot is_bootloader_grub2_bls is_sle is_leap is_staging);

sub run {
    my ($self) = shift;

    # Verify Installation Settings overview is displayed as starting point
    assert_screen "installation-settings-overview-loaded", 90;
    my $is_textmode = check_var('VIDEOMODE', 'text');
    if ($is_textmode) {
        # Select section booting on Installation Settings overview on text mode
        send_key $cmd{change};
        assert_screen 'inst-overview-options';
        send_key 'alt-b';
    }
    else {
        # Select section booting on Installation Settings overview (video mode)
        send_key_until_needlematch 'booting-section-selected', 'tab', 26, 1;
        send_key 'ret';
    }

    assert_screen 'inst-bootloader-settings';

    # Select systemd-boot as bootloader
    send_key 'alt-b', wait_screen_change => 1;
    send_key 'spc', wait_screen_change => 1;
    send_key_until_needlematch 'inst-bootloader-systemd-boot-selected', 'down' if is_bootloader_sdboot;
    send_key_until_needlematch 'inst-bootloader-grub2-bls-selected', 'down' if is_bootloader_grub2_bls;
    send_key 'ret', wait_screen_change => 1;    # Select the option

    unless (get_var('KEEP_GRUB_TIMEOUT')) {
        # In the case the bootloader selected is the same we're expecting, we have to cycle
        # through the different controls in the ui to reach the highligted tab, since pressing
        # enter, does not move us to the 'OK' button anymore.
        send_key_until_needlematch 'inst-bootloader-settings-first_tab_highlighted', 'tab';

        send_key_until_needlematch 'inst-bootloader-options-highlighted', 'right', 20, 2;
        # changes are for now confined to Staging:F
        if (!is_sle && !is_leap && (is_bootloader_grub2_bls || is_bootloader_sdboot)) {
            # Microos and Tumbleweed are using systemd-boot and grub-bls respectively
            # the UI doesn't accept -1 anymore, but has a checkbox to disable the timeout
            send_key 'alt-a';
            send_key 'spc' if $is_textmode;
            wait_still_screen(1);
        } else {
            # Keep old behavior around for now
            # Select Timeout dropdown box and disable
            send_key 'alt-t';
            # "-1" does not work and "menu-force" is not accepted, so use something else for the time being as workaround
            record_soft_failure "boo#1216366: Disabling the timeout is not possible";
            type_string "42";
        }

        wait_still_screen(1);
        save_screenshot;
        # ncurses uses blocking modal dialog, so press return is needed
        send_key 'ret' if $is_textmode;
    }

    send_key $cmd{ok};
    # It doesn't immediately notice that the overview needs recalculation.
    # Give it some time to make sure that it's fully loaded.
    assert_screen 'installation-settings-overview-loaded', 220;
    wait_still_screen 3;
    assert_screen 'installation-settings-overview-loaded', 220;
}
1;

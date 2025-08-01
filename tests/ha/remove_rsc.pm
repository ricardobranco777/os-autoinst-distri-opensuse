# SUSE's openQA tests
#
# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: crmsh
# Summary: Remove all the resources except stonith/sbd
# Maintainer: QE-SAP <qe-sap@suse.de>

use base 'haclusterbasetest';
use strict;
use warnings;
use testapi;
use lockapi;
use hacluster;

sub run {
    my $cluster_name = get_cluster_name;

    # Waiting for the other nodes to be ready
    barrier_wait("RSC_REMOVE_INIT_$cluster_name");

    if (is_node(1)) {
        # Stop all the running or failed resources except stonith-sbd
        # NOTE: In a production environment, this could be more proper to stop the resource group
        # to avoid misconfiguration but it works here as we are going to delete the resources in the next step
        save_state;
        assert_script_run("for rsc in \$($crm_mon_cmd | awk '/(Started\$|FAILED)/ { if (!seen[\$0]++ && \$0 !~ /stonith-sbd/) print \$1}'); do crm resource stop \$rsc; done");
        sleep 5;
        save_state;

        # Delete all the stopped resources
        assert_script_run("for rsc in \$($crm_mon_cmd | awk '/(Stopped\$|\\(disabled\\)\$)/ { if (!seen[\$0]++) print \$1}'); do crm configure delete \$rsc; done");
        sleep 5;
        save_state;
    }
    # Waiting for the other nodes to be ready
    barrier_wait("RSC_REMOVE_DONE_$cluster_name");
}

1;

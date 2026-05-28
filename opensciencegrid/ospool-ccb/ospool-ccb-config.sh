#!/bin/bash

# this script is invoked by the OSG container init setup


function kill_container()
{
    echo "Restarting container: $1" 2>&1
    sleep 180
    exit 1
}

# create an env file so we can have the cron jobs run with the
# same environment as the init.d run
if [ -e /etc/ospool.env ]; then
    . /etc/ospool.env
else
    cat >/etc/ospool.env <<EOF
export OSPOOL_ENVIRONMENT=$OSPOOL_ENVIRONMENT
export OSPOOL_CCB_HOSTNAME=$OSPOOL_CCB_HOSTNAME
EOF
fi

# git repo - fetch / check for updates
NEEDS_UPDATE=1
cd /opt
if [ ! -e osg-flock ]; then
    git clone https://github.com/opensciencegrid/osg-flock.git || kill_container "Unable to pull Git repo"
else
    # only continue with the config if changes are found
    cd osg-flock
    git fetch --quiet
    # Count commits that exist on the upstream branch but NOT on local branch
    CHANGES_COUNT=$(git rev-list --count HEAD..@{u})
    if [ "$CHANGES_COUNT" -eq 0 ]; then
        echo "The osg-flock checkout is in sync with git repo. Nothing to do."
        NEEDS_UPDATE=0
    fi
    git pull
fi

if [ $NEEDS_UPDATE -eq 1 ]; then

    # fix ownership/permissions on mounted directories
    chown -R condor:condor /var/log/condor
    chown -R condor:condor /var/lib/condor/spool
    
    # most config comes from the shared github repo below, but here is 
    # what is specific to the cm pod
    cat >/etc/condor/config.d/10-ospool-ccb.config <<EOF

DAEMON_LIST = MASTER, SHARED_PORT, COLLECTOR

# FULL_HOSTNAME seems to be causing issues with HTCondor 23
#CONDOR_HOST = \$(FULL_HOSTNAME)
CONDOR_HOST = 127.0.0.1

HOST_ALIAS = $OSPOOL_CCB_HOSTNAME
TCP_FORWARDING_HOST = $OSPOOL_CCB_HOSTNAME

UPDATE_COLLECTOR_WITH_TCP = True

USE_SHARED_PORT = True
SHARED_PORT_MAX_WORKERS = 1000
SHARED_PORT_PORT = 9618

# Setup 10 child collectors
use feature:ChildCollector(1)
use feature:ChildCollector(2)
use feature:ChildCollector(3)
use feature:ChildCollector(4)
use feature:ChildCollector(5)
use feature:ChildCollector(6)
use feature:ChildCollector(7)
use feature:ChildCollector(8)
use feature:ChildCollector(9)
use feature:ChildCollector(10)

# no forwarding here - these are only used for CCB
TOP_COLLECTOR_HOST =

# limit logging
COLLECTOR1.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR2.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR3.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR4.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR5.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR6.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR7.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR8.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR9.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)
COLLECTOR10.MAX_COLLECTOR_LOG = \$(MAX_DEFAULT_LOG)

EOF

    echo "Installing HTCondor credentials..."
    cd /etc/ospool-creds/idkeys.d
    for FILE in *; do
        install -o root -g root -m 0600 $FILE /etc/condor/passwords.d/$FILE
    done
    cd /etc/ospool-creds/idtokens.d
    for FILE in *; do
        install -o root -g root -m 0600 $FILE /etc/condor/tokens.d/$FILE
    done
    # the gwms frontend generates tokens with kid=FRONTEND - for now make
    # sure we have a copy of our flock.opensciencegrid.org password in the
    # correct location
    install -o root -g root -m 0600 \
            /etc/condor/passwords.d/flock.opensciencegrid.org \
            /etc/condor/passwords.d/FRONTEND
    # SSL auth - the main hostcert comes from k8s certmanager
    cd /etc/ospool-creds/tls.d
    install -o root -g root -m 0644 tls.crt /etc/pki/tls/certs/localhost.crt
    install -o root -g root -m 0600 tls.key /etc/pki/tls/private/localhost.key
    
    # condor config
    rm -f /etc/condor/config.d/*ospoolgit*
    cp /opt/osg-flock/ospool.osg-htc.org/$OSPOOL_ENVIRONMENT/htcondor-config.d/* /etc/condor/config.d/
    rm -f /etc/condor/config.d/90_high_availability.config
    rm -f /etc/condor/config.d/95_negotiator_osgflockgit.config
    
    cd /opt/osg-flock/ospool.osg-htc.org
    echo "Writing out new /etc/condor/certs/condor_mapfile ..."
    mkdir -p /etc/condor/certs
    ./fe-admin --target-env $OSPOOL_ENVIRONMENT --htcondor-mapfile >/etc/condor/certs/condor_mapfile
    echo "Writing out new /etc/condor/config.d/95_flocking_ospoolgit.config ..."
    ./fe-admin --target-env $OSPOOL_ENVIRONMENT --htcondor-config >/etc/condor/config.d/95_flocking_ospoolgit.config
    
    # this will fail during initial configuration, but work once the pool is up
    /usr/sbin/condor_reconfig || true

fi


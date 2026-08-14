#!/bin/bash
set -e

if [ ! -d /app/nopaystation_scripts ]; then
    echo "Seeding /app with nopaystation_scripts..."
    cp -a /opt/nps-seed/nopaystation_scripts /app/nopaystation_scripts
fi

exec "$@"

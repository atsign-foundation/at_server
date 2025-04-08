#!/bin/bash
# Create atSign/atServers
cd /tmp/setup/
./createConf.sh ./atsigns

# Copy rootca/cacert.pem into place
# This is needed if using -v to mount over the certs dir
cp /atsign/secondary/base/rootca/cacert.pem /atsign/secondary/base/certs/

# Run supervisord as root
sed -i '/\[supervisord\]/a user=root' /etc/supervisor/supervisord.conf

supervisord  -c /etc/supervisor/supervisord.conf -n 
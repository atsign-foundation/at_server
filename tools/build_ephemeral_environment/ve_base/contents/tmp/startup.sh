#!/bin/bash
cd /tmp/setup/
./createConf.sh ./atsigns

# Run supervisord as root
sed -i '/\[supervisord\]/a user=root' /etc/supervisor/supervisord.conf

supervisord  -c /etc/supervisor/supervisord.conf -n 
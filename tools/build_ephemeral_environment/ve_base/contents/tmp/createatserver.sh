#!/bin/bash
cd /tmp/setup/
./createConf.sh ./atsigns
supervisord  -c /etc/supervisor/supervisord.conf
#!/bin/bash
set -euo pipefail

mkdir -p /atsign/logs
mkdir -p /atsign/root
mkdir -p /atsign/secondary
mkdir -p /atsign/atservers
mkdir -p /atsign/supervisor/conf.d

exec supervisord -c /etc/supervisor/supervisord.conf

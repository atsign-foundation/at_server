#!/bin/bash
set -euo pipefail
echo "127.0.0.1 vip.ve.atsign.zone" | sudo tee -a /etc/hosts > /dev/null
exec supervisord -c /etc/supervisor/supervisord.conf

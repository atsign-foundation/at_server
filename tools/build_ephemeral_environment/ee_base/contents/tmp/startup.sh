#!/bin/bash
#
# Ephemeral environment container entrypoint.
#
# When EPHEMERAL_BASE_PORT is set (e.g. 2500) we shift every bind port
# into the contiguous range [BASE, BASE+99]:
#   atDirectory  -> BASE
#   atServers    -> BASE+1 .. BASE+80
#   (reserved)   -> BASE+81 .. BASE+98
#   Redis        -> BASE+99
# This lets multiple EE containers run side-by-side on one host.
#
# When EPHEMERAL_BASE_PORT is unset, the existing FIRST_PORT / DNS_FQDN
# behaviour (atDirectory on 64, atServers from FIRST_PORT, redis on
# 6379) is preserved unchanged.

set -euo pipefail

if [[ -n "${EPHEMERAL_BASE_PORT:-}" ]]; then
  BASE=${EPHEMERAL_BASE_PORT}
  ROOT_PORT=${BASE}
  REDIS_PORT=$((BASE + 99))
  export FIRST_PORT=$((BASE + 1))
  export rootServerPort=${ROOT_PORT}

  sed -i "s/^port .*/port ${REDIS_PORT}/" /etc/redis/redis.conf
  sed -i "s/-p 6379/-p ${REDIS_PORT}/" /etc/supervisor/conf.d/40_root.conf
  # /tmp/import.sh pipes records to redis-cli with no -p, so it defaults
  # to 6379; after shifting we have to point it at the new redis port.
  sed -i "s|redis-cli --pipe|redis-cli -p ${REDIS_PORT} --pipe|" /tmp/import.sh
fi

# Create atSign/atServers
cd /tmp/setup/
./createConf.sh ./atsigns

# Copy rootca/cacert.pem into place
# This is needed if using -v to mount over the certs dir
cp /atsign/secondary/base/rootca/cacert.pem /atsign/secondary/base/certs/

# Run supervisord as root
sed -i '/\[supervisord\]/a user=root' /etc/supervisor/supervisord.conf

supervisord -c /etc/supervisor/supervisord.conf -n

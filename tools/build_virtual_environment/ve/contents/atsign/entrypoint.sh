#!/usr/bin/env bash
#
# Virtualenv container entrypoint.
#
# If VIRTUALENV_BASE_PORT is unset, behaviour is unchanged: services
# bind to their original ports (atDirectory 64, atServers 25000-25039,
# Redis 6379) and we just exec supervisord.
#
# If VIRTUALENV_BASE_PORT is set (e.g. 30000), we shift every bind port
# into the [BASE, BASE+99] range:
#   atDirectory  -> BASE
#   atServers    -> BASE+1 .. BASE+80
#   HTTPS        -> BASE+98
#   Redis        -> BASE+99
# This makes it possible to run several VE containers side-by-side on
# one host without port collisions.

set -euo pipefail

if [[ -z "${VIRTUALENV_BASE_PORT:-}" ]]; then
  exec supervisord -n
  exit $?
fi

BASE=${VIRTUALENV_BASE_PORT}
ROOT_PORT=${BASE}
REDIS_PORT=$((BASE + 99))
HTTPS_PORT=$((BASE + 98))
SECONDARY_BASE=$((BASE + 1))
SHIFT=$((SECONDARY_BASE - 25000))

# Redis bind port
sed -i "s/^port .*/port ${REDIS_PORT}/" /etc/redis/redis.conf

# root_server: redis client port (the -p arg) and bind port (env var)
export rootServerPort="${ROOT_PORT}"
# root_server: HTTPS bind port (env var read by AtRootConfig.httpsPort)
export httpsPort="${HTTPS_PORT}"
sed -i "s/-p 6379/-p ${REDIS_PORT}/" /etc/supervisor/conf.d/30_root.conf

# Secondary atServer supervisord program blocks: rewrite the -p N arg
for f in /etc/supervisor/conf.d/[0-9]*_*.conf; do
  grep -q '/atsign/secondary/secondary' "$f" || continue
  old=$(grep -oE -- '-p [0-9]+' "$f" | awk '{print $2}')
  new=$((old + SHIFT))
  sed -i "s/-p ${old}/-p ${new}/" "$f"
done

# /tmp/records (redis seed lines): shift the vip.ve.atsign.zone:<port>
perl -i -pe 's{vip\.ve\.atsign\.zone:(\d+)}{"vip.ve.atsign.zone:" . ($1 + '"$SHIFT"')}ge' /tmp/records

# /tmp/import.sh pipes records to redis-cli with no -p, so it defaults to 6379;
# after shifting we have to point it at the new redis port.
sed -i "s|redis-cli --pipe|redis-cli -p ${REDIS_PORT} --pipe|" /tmp/import.sh

exec supervisord -n

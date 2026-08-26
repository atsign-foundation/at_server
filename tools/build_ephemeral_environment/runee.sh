#!/usr/bin/env bash
#
# runee.sh — bring up an ephemeral environment (EE) container with port-
# shifted services so multiple EEs can run side-by-side on one host.
#
# Usage: runee.sh <container-name> <base-port> [image-tag]
#
# image-tag defaults to the published atsigncompany/ephemeral:latest. Pass the
# tag buildee.sh produced to run an EE built from this working tree instead.
#
# The container will bind:
#   atDirectory  -> <base>
#   atServers    -> <base>+1 .. <base>+80
#   (reserved)   -> <base>+81 .. <base>+98
#   Redis        -> <base>+99
# All host port mappings are bound to 127.0.0.1.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: runee.sh <container-name> <base-port> [image-tag]" >&2
  exit 2
fi

NAME=$1
BASE=$2
IMAGE=${3:-atsigncompany/ephemeral:latest}

if [[ ! "$BASE" =~ ^[0-9]+$ ]]; then
  echo "base-port must be numeric (got: $BASE)" >&2
  exit 2
fi
if (( BASE < 1 || BASE + 99 > 65535 )); then
  echo "base-port out of range: <base>+99 must be <= 65535" >&2
  exit 2
fi

if docker ps --format '{{.Names}}' | grep -Fxq "$NAME"; then
  echo "container '$NAME' is already running" >&2
  exit 1
fi

TOP=$((BASE + 99))
COMPOSE_FILE="docker-compose-${NAME}.yaml"

cat > "$COMPOSE_FILE" <<EOF
name: ${NAME}
services:
  ephemeral:
    container_name: ${NAME}
    image: ${IMAGE}
    ports:
      - '127.0.0.1:${BASE}-${TOP}:${BASE}-${TOP}'
    extra_hosts:
      - 'vip.ve.atsign.zone:127.0.0.1'
    environment:
      - EPHEMERAL_BASE_PORT=${BASE}
      # Named explicitly rather than left to createConf.sh's default branch,
      # which until recently substituted a placeholder that is not in
      # config.yaml — leaving every atServer's root_server.url as the literal
      # string DNS_FQDN, so no atSign could look up any other. Passing it here
      # makes runee.sh correct against published images too.
      - DNS_FQDN=vip.ve.atsign.zone
EOF

docker compose -f "$COMPOSE_FILE" up -d

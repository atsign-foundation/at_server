#!/usr/bin/env bash
# Runs the adverse-peer tests (adverse/adverse_peers_test.dart) against a
# virtualenv whose @alice🛠 is reached through a fault proxy, so a test can
# delay, trickle, stall or cut @bob🛠's atServer's traffic to @alice🛠's, and
# freeze or restart @alice🛠's atServer.
#
#   VE_IMAGE=<tag> ./runAdverse.sh <basePort>   # an image already built
#   ./runAdverse.sh <basePort>                  # build from this checkout
#
# A base port is required (VIRTUALENV_BASE_PORT or the first argument): the
# proxy listens on base+91 and takes control lines on base+90, inside the block
# the virtualenv publishes. The image is built with buildve.sh under this
# checkout's own tag only, leaving at_virtual_env:local alone.
#
# Output: adverse/results/adverse_<host>_<utc>.txt, the full log, with the
# proxy's own log at the end.
set -euo pipefail

cd "$(dirname -- "$0")/../.."
repoDir=$(pwd)
packDir="${repoDir}/tests/at_functional_test"

source "${repoDir}/tools/build_virtual_environment/live_rig.sh"
live_rig_lock "$repoDir"

VIRTUALENV_BASE_PORT="${1:-${VIRTUALENV_BASE_PORT:-}}"
if [[ -z "$VIRTUALENV_BASE_PORT" ]]; then
  echo "runAdverse.sh: a base port is required (VIRTUALENV_BASE_PORT or the first argument)" >&2
  exit 2
fi
export VIRTUALENV_BASE_PORT
export rootServerPort="$VIRTUALENV_BASE_PORT"
base="$VIRTUALENV_BASE_PORT"
redisPort=$((base + 99))
controlPort=$((base + 90))
proxyPort=$((base + 91))
alicePort=$((base + 1))

for port in "$base" "$controlPort" "$proxyPort"; do
  holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN || true)
  if [[ -n "$holder" ]]; then
    echo "runAdverse.sh: port $port is already in use; not touching it:" >&2
    echo "$holder" >&2
    exit 1
  fi
done

containerName=$(live_rig_container_name at_server_adverse_cont)
proxyName="${containerName}_faultproxy"
veImage="${VE_IMAGE:-$(live_rig_image "$repoDir")}"
if [[ -z "${VE_IMAGE:-}" ]]; then
  bash "${repoDir}/tools/build_virtual_environment/buildve.sh" -t "$veImage"
fi

resultsDir="${packDir}/adverse/results"
mkdir -p "$resultsDir"
out="${resultsDir}/adverse_$(hostname -s)_$(date -u +%Y%m%dT%H%M%SZ).txt"

started=""
proxyStarted=""
cleanup() {
  if [[ -n "$proxyStarted" ]]; then
    {
      echo
      echo "---- fault proxy log"
      docker logs "$proxyName" 2>&1 || true
    } >> "$out"
    docker stop "$proxyName" >/dev/null 2>&1 || true
  fi
  if [[ -n "$started" ]]; then
    echo "Stopping docker container ${containerName}"
    docker stop "$containerName" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker run -d --rm --name "$containerName" \
  -e testingMode="true" -e httpsEnabled="true" \
  -e "VIRTUALENV_BASE_PORT=${base}" \
  -p "${base}-$((base + 99)):${base}-$((base + 99))" \
  "$veImage" bash /atsign/entrypoint.sh
started=yes

cd "$packDir"
dart pub get
dart run test/check_docker_readiness.dart
dart run test/check_root_server_readiness.dart
(cd "${repoDir}/tools/build_virtual_environment/install_PKAM_Keys" &&
  dart pub get && dart bin/install_PKAM_Keys.dart)
dart run test/check_test_env.dart

docker run -d --rm --name "$proxyName" --network "container:${containerName}" \
  -v "${packDir}/adverse:/w:ro" dart:3.13.5 \
  dart /w/fault_proxy.dart "$proxyPort" "$alicePort" "$controlPort"
proxyStarted=yes

reply=""
for _ in $(seq 1 60); do
  if exec 3<>"/dev/tcp/127.0.0.1/${controlPort}" 2>/dev/null; then
    printf 'stats\n' >&3
    read -r -t 5 reply <&3 || true
    exec 3<&- 3>&-
    [[ "$reply" == ok* ]] && break
  fi
  sleep 1
done
if [[ "$reply" != ok* ]]; then
  echo "runAdverse.sh: the fault proxy did not answer on ${controlPort}" >&2
  exit 1
fi

# The virtualenv's redis takes the password its own redis.conf sets.
redisCli() {
  docker exec "$containerName" sh -c \
    'pass=$(awk "/^requirepass /{print \$2}" /etc/redis/redis.conf);
     port=$1; shift; exec redis-cli --no-auth-warning -p "$port" -a "$pass" "$@"' \
    redisCli "$redisPort" "$@"
}
redisCli set 'alice🛠' "vip.ve.atsign.zone:${proxyPort}"
record=$(redisCli get 'alice🛠')
if [[ "$record" != "vip.ve.atsign.zone:${proxyPort}" ]]; then
  echo "runAdverse.sh: @alice🛠's atDirectory record reads '${record}'" >&2
  exit 1
fi

{
  echo "host:     $(hostname -s)"
  echo "date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "checkout: $(git -C "$repoDir" rev-parse --short HEAD) $(git -C "$repoDir" rev-parse --abbrev-ref HEAD)"
  echo "image:    $veImage $(docker image inspect --format '{{.Id}}' "$veImage")"
  echo "labels:   $(docker image inspect --format '{{json .Config.Labels}}' "$veImage")"
  echo "base:     ${base} (proxy ${proxyPort}, control ${controlPort})"
  echo "record:   alice🛠 -> ${record}"
  echo
} > "$out"

set +e
ADVERSE_CONTAINER="$containerName" perl -e 'alarm shift; exec @ARGV' \
  "${ADVERSE_TIMEOUT:-1800}" \
  dart test --concurrency=1 adverse/adverse_peers_test.dart -r expanded \
  >> "$out" 2>&1
rc=$?
set -e

echo "adverse exit: $rc" >> "$out"
echo "full results: $out"
exit $rc

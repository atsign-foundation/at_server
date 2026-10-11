#!/usr/bin/env bash
# Runs the cross-atServer lookup and notify bench (bench/cross_atserver_bench.dart)
# against a virtualenv: one built from this checkout, or VE_IMAGE when set.
#
#   ./runBench.sh [basePort]                    # build from this checkout
#   VE_IMAGE=<tag> ./runBench.sh [basePort]     # an image already built
#   BENCH_ARGS="--lookups 5000 --concurrency 1,4,16" ./runBench.sh
#
# The base port works as in runLocal.sh: VIRTUALENV_BASE_PORT or the first
# argument shifts the virtualenv into [base, base+99]. The image is built with
# buildve.sh under this checkout's own tag only, leaving at_virtual_env:local,
# which other checkouts' live packs run, untouched.
#
# Output: bench/results/cross_atserver_<host>_<utc>.txt, the full log, header
# included (commit, image and its labels).
set -euo pipefail

cd "$(dirname -- "$0")/../.."
repoDir=$(pwd)
packDir="${repoDir}/tests/at_functional_test"

source "${repoDir}/tools/build_virtual_environment/live_rig.sh"
live_rig_lock "$repoDir"

VIRTUALENV_BASE_PORT="${1:-${VIRTUALENV_BASE_PORT:-}}"
if [[ -n "$VIRTUALENV_BASE_PORT" ]]; then
  export VIRTUALENV_BASE_PORT
  export rootServerPort="$VIRTUALENV_BASE_PORT"
  veEnvArgs=(-e "VIRTUALENV_BASE_PORT=${VIRTUALENV_BASE_PORT}")
  vePortArgs=(-p "${VIRTUALENV_BASE_PORT}-$((VIRTUALENV_BASE_PORT + 99)):${VIRTUALENV_BASE_PORT}-$((VIRTUALENV_BASE_PORT + 99))")
  veCmd=(bash /atsign/entrypoint.sh)
  firstPort="$VIRTUALENV_BASE_PORT"
else
  veEnvArgs=()
  vePortArgs=(-p 6379:6379 -p 25000-25040:25000-25040 -p 64:64)
  veCmd=()
  firstPort=64
fi

holder=$(lsof -nP -iTCP:"$firstPort" -sTCP:LISTEN || true)
if [[ -n "$holder" ]]; then
  echo "runBench.sh: port $firstPort is already in use; not touching it:" >&2
  echo "$holder" >&2
  exit 1
fi

containerName=$(live_rig_container_name at_server_bench_cont)
veImage="${VE_IMAGE:-$(live_rig_image "$repoDir")}"
if [[ -z "${VE_IMAGE:-}" ]]; then
  bash "${repoDir}/tools/build_virtual_environment/buildve.sh" -t "$veImage"
fi

started=""
cleanup() {
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
  "${veEnvArgs[@]}" "${vePortArgs[@]}" \
  "$veImage" "${veCmd[@]}"
started=yes

cd "$packDir"
dart pub get
dart run test/check_docker_readiness.dart
dart run test/check_root_server_readiness.dart
(cd "${repoDir}/tools/build_virtual_environment/install_PKAM_Keys" &&
  dart pub get && dart bin/install_PKAM_Keys.dart)
dart run test/check_test_env.dart

resultsDir="${packDir}/bench/results"
mkdir -p "$resultsDir"
out="${resultsDir}/cross_atserver_$(hostname -s)_$(date -u +%Y%m%dT%H%M%SZ).txt"
{
  echo "host:     $(hostname -s)"
  echo "uname:    $(uname -a)"
  echo "dart:     $(dart --version 2>&1)"
  echo "date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "checkout: $(git -C "$repoDir" rev-parse --short HEAD) $(git -C "$repoDir" rev-parse --abbrev-ref HEAD)"
  echo "image:    $veImage $(docker image inspect --format '{{.Id}}' "$veImage")"
  echo "labels:   $(docker image inspect --format '{{json .Config.Labels}}' "$veImage")"
  echo "base:     ${VIRTUALENV_BASE_PORT:-unshifted}"
  echo "args:     ${BENCH_ARGS:-}"
  echo
} > "$out"

# AOT, so the client is not the slow side of what it measures.
binDir=$(mktemp -d)
dart compile exe bench/cross_atserver_bench.dart -o "${binDir}/bench" >> "$out" 2>&1

# Bound well above the default run (a few minutes); BENCH_TIMEOUT overrides.
set +e
# shellcheck disable=SC2086
perl -e 'alarm shift; exec @ARGV' "${BENCH_TIMEOUT:-1800}" \
  "${binDir}/bench" ${BENCH_ARGS:-} >> "$out" 2>&1
rc=$?
set -e
rm -rf "$binDir"

echo "bench exit: $rc" >> "$out"
echo "full results: $out"
exit $rc

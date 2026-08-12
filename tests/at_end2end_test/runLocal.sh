#!/usr/bin/env bash
#
# Run the end-to-end pack locally against a virtualenv container built from the
# working tree, instead of against the long-lived @cicd atSigns that CI uses.
#
# The two atSigns under test are the VE's @alice🛠 and @bob🛠 (separate
# atServers inside one container, so the cross-atSign paths — notify, plookup,
# cached keys, pol-authenticated lookup:all — are all genuinely exercised).
#
# Two tracked files are rewritten for the run and restored on exit, mirroring
# what the CI job does to them (.github/workflows/at_server.yaml swaps in
# config12.yaml and writes the @cicd keys over at_demo_data.dart):
#   config/config.yaml     -> the local VE's atDirectory and atServer ports
#   test/at_demo_data.dart -> re-export of package:at_demo_data, so the demo
#                             atSigns' PKAM private keys are in the map. Left
#                             as the tracked dummy, pkam_utils falls back to
#                             reading $HOME/.atsign/keys — the real ones.

set -euo pipefail

originalDir=$(pwd)
cd "$(dirname -- "$0")"
e2eDir=$(pwd)
cd ../../
repoDir=$(pwd)

containerName=at_server_e2e_cont

# Optional VE base port. Set VIRTUALENV_BASE_PORT (env) or pass it as the first
# argument to run the virtualenv on a shifted port range, so it doesn't clash
# with another VE already running on the default ports. The ve entrypoint binds
# atDirectory to BASE, atServers to BASE+1.., Redis to BASE+99
# (tools/build_virtual_environment/ve/contents/atsign/entrypoint.sh). Unset =>
# original ports (atDirectory 64, atServers 25000.., Redis 6379).
VIRTUALENV_BASE_PORT="${1:-${VIRTUALENV_BASE_PORT:-}}"
if [[ -n "$VIRTUALENV_BASE_PORT" ]]; then
  export VIRTUALENV_BASE_PORT
  export rootServerPort="$VIRTUALENV_BASE_PORT" # install_PKAM_Keys reads this
  veEnvArgs="-e VIRTUALENV_BASE_PORT=${VIRTUALENV_BASE_PORT}"
  vePortArgs="-p ${VIRTUALENV_BASE_PORT}-$((VIRTUALENV_BASE_PORT + 99)):${VIRTUALENV_BASE_PORT}-$((VIRTUALENV_BASE_PORT + 99))"
  veCmd="bash /atsign/entrypoint.sh"
  rootPort="$VIRTUALENV_BASE_PORT"
  portShift=$((VIRTUALENV_BASE_PORT + 1 - 25000))
  echo "Using VE base port ${VIRTUALENV_BASE_PORT} (atServers ${VIRTUALENV_BASE_PORT}+1.., Redis +99)"
else
  veEnvArgs=""
  vePortArgs="-p 6379:6379 -p 25000-25040:25000-25040 -p 64:64 -p 443:443"
  veCmd=""
  rootPort=64
  portShift=0
fi

# Ports the VE assigns to the demo atSigns
# (tools/build_virtual_environment/ve_base/contents/tmp/setup/create_demo_accounts.sh),
# shifted the same way the entrypoint shifts them.
firstAtSign='@alice🛠'
firstAtSignPort=$((25000 + portShift))
secondAtSign='@bob🛠'
secondAtSignPort=$((25003 + portShift))

# The VE's TLS certs are issued for vip.ve.atsign.zone, which resolves to
# 127.0.0.1 — so the tests must dial that name, not localhost, or the
# handshake fails on a hostname mismatch.
veHost=vip.ve.atsign.zone

configFile="${e2eDir}/config/config.yaml"
demoDataFile="${e2eDir}/test/at_demo_data.dart"
backupDir=$(mktemp -d)
filesStashed=false

# Idempotent: a signal runs this trap AND then the EXIT trap, so the second
# pass must not try to restore from a backup dir the first pass removed.
cleanedUp=false
cleanup() {
  if [[ "$cleanedUp" == true ]]; then
    return
  fi
  cleanedUp=true
  if [[ "$filesStashed" == true ]]; then
    echo "Restoring config/config.yaml and test/at_demo_data.dart"
    cp "${backupDir}/config.yaml" "$configFile"
    cp "${backupDir}/at_demo_data.dart" "$demoDataFile"
  fi
  rm -rf "$backupDir"
  echo "Stopping docker container ${containerName}"
  docker stop "$containerName" >/dev/null 2>&1 || true
  cd "$originalDir" || true
}
trap cleanup EXIT INT TERM

# The VE image built below is `FROM atsigncompany/vebase:latest` (see
# tools/build_virtual_environment/ve/Dockerfile), whose baked TLS certs expire
# periodically — they are refreshed by .github/workflows/refreshcerts.yaml,
# which republishes the base image. `docker build` reuses a local base image
# without checking the registry, so a stale local vebase means expired certs and
# the readiness checks below time out. Force-pull the current published base
# first. (Tolerate failure so offline runs fall back to the local image — its
# TLS certs may be stale.)
echo "Force-pulling atsigncompany/vebase:latest (keeps the VE TLS certs fresh)"
docker pull atsigncompany/vebase:latest \
  || echo "WARNING: could not pull atsigncompany/vebase:latest; using the local image (its TLS certs may be stale)"

echo "Generate atDirectory binary (root) [in dart:3.11.2 Linux container]"
# Compile the binaries inside a Linux Dart container so they run inside the
# Linux at_virtual_env container we build below. Compiling on the host
# (e.g. on macOS) produces a Mach-O executable that the container's
# supervisor can't exec — every secondary then exits 127. Pinned to the
# same dart version vebase uses (tools/build_virtual_environment/ve_base/Dockerfile).
docker run --rm \
  -v "${repoDir}:/app" \
  -w /app/packages/at_root_server \
  dart:3.11.2 \
  sh -c 'dart pub get && dart compile exe bin/main.dart -o root'

echo "Generate atServer binary (secondary) [in dart:3.11.2 Linux container]"
docker run --rm \
  -v "${repoDir}:/app" \
  -w /app/packages/at_secondary_server \
  dart:3.11.2 \
  sh -c 'dart pub get && dart compile exe bin/main.dart -o secondary'

echo "copy root and secondary binaries to tools/build_virtual_environment/ve"
cd "$repoDir"
mkdir -p tools/build_virtual_environment/ve/contents/atsign/root
cp packages/at_root_server/root tools/build_virtual_environment/ve/contents/atsign/root/
cp packages/at_root_server/pubspec.yaml tools/build_virtual_environment/ve/contents/atsign/root/
chmod 755 tools/build_virtual_environment/ve/contents/atsign/root/root
cp packages/at_secondary_server/secondary tools/build_virtual_environment/ve/contents/atsign/secondary/
cp packages/at_secondary_server/pubspec.yaml tools/build_virtual_environment/ve/contents/atsign/secondary/
chmod 755 tools/build_virtual_environment/ve/contents/atsign/secondary/secondary

echo "Build docker image"
cd "${repoDir}/tools/build_virtual_environment/ve"
docker build -f ./Dockerfile -t at_virtual_env:local .

# at_functional_test's runner leaves at_server_func_cont holding the same port
# range; a leftover from either pack blocks this one's port binds.
echo "Stopping any running virtualenv containers"
docker stop "$containerName" >/dev/null 2>&1 || true
docker stop at_server_func_cont >/dev/null 2>&1 || true

echo "Run docker container"
# shellcheck disable=SC2086 # veEnvArgs/vePortArgs/veCmd are deliberately split
docker run -d --rm --name "$containerName" \
  -e testingMode="true" -e httpsEnabled="true" \
  $veEnvArgs $vePortArgs \
  at_virtual_env:local $veCmd

echo "Pointing config/config.yaml at the local virtualenv"
cp "$configFile" "${backupDir}/config.yaml"
cp "$demoDataFile" "${backupDir}/at_demo_data.dart"
filesStashed=true

cat > "$configFile" <<EOF
# GENERATED BY runLocal.sh — restored to the tracked version when it exits.
# The Atsign Protocol root server configuration
root_server:
  port: ${rootPort}
  url: '${veHost}'

first_atsign_server:
  first_atsign_name: '${firstAtSign}'
  first_atsign_port: ${firstAtSignPort}
  first_atsign_url: ${veHost}

second_atsign_server:
  second_atsign_name: '${secondAtSign}'
  second_atsign_port: ${secondAtSignPort}
  second_atsign_url: ${veHost}
EOF

cat > "$demoDataFile" <<'EOF'
// GENERATED BY runLocal.sh — restored to the tracked dummy when it exits.
//
// The tracked version of this file holds empty maps, which CI overwrites with
// the @cicd atSigns' keys. Running against the local virtualenv, the atSigns
// under test are demo atSigns, so the published demo keys are what we need.
export 'package:at_demo_data/at_demo_data.dart'
    show pkamPrivateKeyMap, cramKeyMap;
EOF

echo "Install dependencies"
cd "$e2eDir"
dart pub get

echo "Check atDirectory and atServer readiness"
dart run tool/check_ve_readiness.dart atservers

echo "Load PKAM Keys"
cd "${repoDir}/tools/build_virtual_environment/install_PKAM_Keys"
dart pub get
dart bin/install_PKAM_Keys.dart

echo "Check PKAM keys are installed for the atSigns under test"
cd "$e2eDir"
dart run tool/check_ve_readiness.dart pkam

echo "Run tests"
cd "$e2eDir"
set +e
dart test --concurrency=1
testExitCode=$?
set -e

exit $testExitCode

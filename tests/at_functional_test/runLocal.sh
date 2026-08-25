#!/bin/bash

originalDir=$(pwd)
cd "$(dirname -- "$0")"
cd ../../
repoDir=$(pwd)

# Optional VE base port. Set VIRTUALENV_BASE_PORT (env) or pass it as the first
# argument to run the virtualenv on a shifted port range, so it doesn't clash
# with another VE already running on the default ports. The ve entrypoint binds
# atDirectory to BASE, atServers to BASE+1.., Redis to BASE+99
# (tools/build_virtual_environment/ve/contents/atsign/entrypoint.sh). The Dart
# harness reads VIRTUALENV_BASE_PORT too (config_util, the readiness checks), so
# tests target the shifted ports without editing config.yaml. Unset => original
# ports (atDirectory 64, atServers 25000.., Redis 6379).
VIRTUALENV_BASE_PORT="${1:-${VIRTUALENV_BASE_PORT:-}}"
if [[ -n "$VIRTUALENV_BASE_PORT" ]]; then
  export VIRTUALENV_BASE_PORT
  export rootServerPort="$VIRTUALENV_BASE_PORT" # install_PKAM_Keys reads this
  veEnvArgs="-e VIRTUALENV_BASE_PORT=${VIRTUALENV_BASE_PORT}"
  vePortArgs="-p ${VIRTUALENV_BASE_PORT}-$((VIRTUALENV_BASE_PORT + 99)):${VIRTUALENV_BASE_PORT}-$((VIRTUALENV_BASE_PORT + 99))"
  veCmd="bash /atsign/entrypoint.sh"
  echo "Using VE base port ${VIRTUALENV_BASE_PORT} (atServers ${VIRTUALENV_BASE_PORT}+1.., Redis +99)"
else
  veEnvArgs=""
  vePortArgs="-p 6379:6379 -p 25000-25040:25000-25040 -p 64:64 -p 443:443"
  veCmd=""
fi

# The VE image built below is `FROM atsigncompany/vebase:latest` (see
# tools/build_virtual_environment/ve/Dockerfile), whose baked TLS certs expire
# periodically — they are refreshed by .github/workflows/refreshcerts.yaml,
# which republishes the base image. `docker build` reuses a local base image
# without checking the registry, so a stale local vebase means expired certs and
# the root-server readiness check below times out. Force-pull the current
# published base first. (Tolerate failure so offline runs fall back to the local
# image — its certs may be stale.)
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
  sh -c 'dart pub get && dart compile exe bin/main.dart -o root' || exit 1

echo "Generate atServer binary (secondary) [in dart:3.11.2 Linux container]"
docker run --rm \
  -v "${repoDir}:/app" \
  -w /app/packages/at_secondary_server \
  dart:3.11.2 \
  sh -c 'dart pub get && dart compile exe bin/main.dart -o secondary' || exit 1

echo "copy root and secondary binaries to tools/build_virtual_environment/ve"
cd $repoDir
mkdir -p tools/build_virtual_environment/ve/contents/atsign/root
mkdir -p tools/build_virtual_environment/ve/contents/atsign/secondary
cp packages/at_root_server/root tools/build_virtual_environment/ve/contents/atsign/root/
cp packages/at_root_server/pubspec.yaml tools/build_virtual_environment/ve/contents/atsign/root/
chmod 755 tools/build_virtual_environment/ve/contents/atsign/root/root
cp packages/at_secondary_server/secondary tools/build_virtual_environment/ve/contents/atsign/secondary/
cp packages/at_secondary_server/pubspec.yaml tools/build_virtual_environment/ve/contents/atsign/secondary/
chmod 755 tools/build_virtual_environment/ve/contents/atsign/secondary/secondary

echo "Build docker image"
cd ${repoDir}/tools/build_virtual_environment/ve
ls -laR ./contents
docker build -f ./Dockerfile -t at_virtual_env:local . || exit 1

echo "Stopping any running docker container"
docker stop at_server_func_cont

echo "Run docker container"
docker run -d --rm --name at_server_func_cont \
  -e testingMode="true" -e httpsEnabled="true" \
  $veEnvArgs $vePortArgs \
  at_virtual_env:local $veCmd || exit 1

echo "Check docker readiness to load PKAM keys"
cd ${repoDir}/tests/at_functional_test
dart run test/check_docker_readiness.dart || exit 1

echo "Check root server readiness to load PKAM keys"
cd ${repoDir}/tests/at_functional_test
dart run test/check_root_server_readiness.dart || exit 1

echo "Load PKAM Keys"
cd ${repoDir}/tools/build_virtual_environment/install_PKAM_Keys
dart pub get
dart bin/install_PKAM_Keys.dart || exit 1

echo "Check test environment readiness"
cd ${repoDir}/tests/at_functional_test
dart run test/check_test_env.dart || exit 1

echo "Run tests"
cd ${repoDir}/tests/at_functional_test
dart run test --concurrency=1 || exit 1

cd $originalDir

echo "Stopping docker container at_server_func_cont"
docker stop at_server_func_cont || exit 1

exit 0


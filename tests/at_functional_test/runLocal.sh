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

# Compile and build through buildve.sh, which is the ONLY builder that labels
# the image. An unlabelled VE cannot be told from one built by anybody else, so
# a cross-repo run against it proves nothing — see the header of that script.
# It also force-pulls the base (expired TLS certs) and reads its own labels
# back, so a silently-dropped override fails here rather than surfacing hours
# later as an image somebody refuses to run.
bash "${repoDir}/tools/build_virtual_environment/buildve.sh" || exit 1
cd "$repoDir"

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


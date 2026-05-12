#!/bin/bash

originalDir=$(pwd)
cd "$(dirname -- "$0")"
cd ../../
repoDir=$(pwd)

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
docker stop at_virtual_env_cont

echo "Run docker container"
docker run -d --rm --name at_virtual_env_cont \
  -e testingMode="true" -e httpsEnabled="true" \
  -p 6379:6379 -p 25000-25040:25000-25040 -p 64:64 -p 443:443 \
  at_virtual_env:local || exit 1

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

echo "Stopping docker container at_virtual_env_cont"
docker stop at_virtual_env_cont || exit 1

exit 0


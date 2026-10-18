#!/usr/bin/env bash
set -euo pipefail

# Runs at_client_sdk's live packs against an atServer built from this
# checkout, so a change that breaks the reference SDK shows up before it
# reaches trunk.
#
#   ./runLocal.sh [BASE_PORT] [PACK...]
#
#   ./runLocal.sh               # functional and e2e, legacy fixed ports
#   ./runLocal.sh 27000         # the same, on ports 27000-27099
#   ./runLocal.sh 27000 functional e2e onboarding_cli onboarding_cli_proxy
#
# PACK is functional, e2e, onboarding_cli or onboarding_cli_proxy, and the
# default is functional and e2e. A BASE_PORT, passed or exported as
# VIRTUALENV_BASE_PORT, is handed to each pack's own runLocal.sh.
#
# AT_CLIENT_SDK_DIR names an at_client_sdk clone (default: at_client_sdk
# beside this checkout). AT_CLIENT_SDK_REF names the commit to test (default:
# origin/trunk, fetched first). The packs run from a detached worktree of that
# commit, removed afterwards, so the clone is never changed. A commit whose
# pack runner does not read VIRTUALENV_IMAGE is refused, since it would test
# some other atServer.
#
# buildve.sh builds the atServer image under this checkout's own tag, which
# is passed to each pack as VIRTUALENV_IMAGE; at_virtual_env:local is never
# touched. HOME points at a scratch directory for the run, and PUB_CACHE and
# DOCKER_CONFIG keep their values.
#
# onboarding_cli_proxy also needs host port 443, and the host must resolve
# vip.ve.atsign.zone to 127.0.0.1.
#
# Exits non-zero if any pack fails, after running the rest.

cd "$(dirname -- "$0")/../.."
repoDir=$(pwd)

if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  VIRTUALENV_BASE_PORT="$1"
  shift
fi
basePort="${VIRTUALENV_BASE_PORT:-}"
packs=("$@")
if [[ ${#packs[@]} -eq 0 ]]; then
  packs=(functional e2e)
fi

packDir() {
  case "$1" in
    functional) echo at_functional_test ;;
    e2e) echo at_end2end_test ;;
    onboarding_cli) echo at_onboarding_cli_functional_tests ;;
    onboarding_cli_proxy) echo at_onboarding_cli_functional_tests_proxy ;;
    *) return 1 ;;
  esac
}
for pack in "${packs[@]}"; do
  if ! packDir "$pack" >/dev/null; then
    echo "*** Unknown pack '$pack': use functional, e2e, onboarding_cli or onboarding_cli_proxy" >&2
    exit 2
  fi
done

sdkDir="${AT_CLIENT_SDK_DIR:-${repoDir}/../at_client_sdk}"
sdkRef="${AT_CLIENT_SDK_REF:-origin/trunk}"
if ! git -C "$sdkDir" rev-parse --git-dir >/dev/null; then
  echo "*** No at_client_sdk clone at ${sdkDir}; set AT_CLIENT_SDK_DIR" >&2
  exit 2
fi
if [[ "$sdkRef" == origin/* ]]; then
  echo "*** Fetching ${sdkRef} in ${sdkDir}"
  git -C "$sdkDir" fetch origin "${sdkRef#origin/}"
fi
sdkCommit=$(git -C "$sdkDir" rev-parse --verify "${sdkRef}^{commit}")

for pack in "${packs[@]}"; do
  runner="tests/$(packDir "$pack")/runLocal.sh"
  runnerText=$(git -C "$sdkDir" show "${sdkCommit}:${runner}" || true)
  if [[ "$runnerText" != *VIRTUALENV_IMAGE* ]]; then
    echo "*** at_client_sdk ${sdkCommit} has no ${runner} that reads VIRTUALENV_IMAGE" >&2
    exit 2
  fi
done

source "${repoDir}/tools/build_virtual_environment/live_rig.sh"
live_rig_lock "$repoDir" || exit 1
image=$(live_rig_image "$repoDir")

runDir=$(mktemp -d "${TMPDIR:-/tmp}/client_checks.XXXXXX")
sdkWorktree="${runDir}/at_client_sdk"
cleanup() {
  if [[ -d "$sdkWorktree" ]]; then
    git -C "$sdkDir" worktree remove --force "$sdkWorktree" || true
  fi
  rm -rf "$runDir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "*** Checking out at_client_sdk ${sdkCommit} in ${sdkWorktree}"
git -C "$sdkDir" worktree add --detach "$sdkWorktree" "$sdkCommit"

echo "*** Building ${image} from ${repoDir}"
bash "${repoDir}/tools/build_virtual_environment/buildve.sh" -t "$image"

export PUB_CACHE="${PUB_CACHE:-${HOME}/.pub-cache}"
export DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"
mkdir -p "${runDir}/home"
export HOME="${runDir}/home"
export VIRTUALENV_IMAGE="$image"

results=()
failed=0
for pack in "${packs[@]}"; do
  echo "*** Running at_client_sdk's ${pack} pack against ${image}"
  set +e
  (cd "${sdkWorktree}/tests/$(packDir "$pack")" && ./runLocal.sh ${basePort:+"$basePort"})
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    results+=("${pack}: passed")
  else
    results+=("${pack}: FAILED (exit ${status})")
    failed=1
  fi
done

echo "*** at_client_sdk ${sdkCommit} against ${image}:"
printf '***   %s\n' "${results[@]}"
exit "$failed"

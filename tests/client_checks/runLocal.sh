#!/usr/bin/env bash
set -euo pipefail

# Runs at_client_sdk's live packs against an atServer built from this
# checkout, so a change that breaks the reference SDK shows up before it
# reaches trunk.
#
#   ./runLocal.sh [BASE_PORT] [PACK...]
#
#   ./runLocal.sh               # functional and e2e, on each pack's default ports
#   ./runLocal.sh 27000         # the same, on ports 27000-27099
#   ./runLocal.sh 27000 functional e2e onboarding_cli onboarding_cli_proxy
#
# PACK is functional, e2e, onboarding_cli or onboarding_cli_proxy, and the
# default is functional and e2e. A BASE_PORT, passed or exported as
# VIRTUALENV_BASE_PORT, is handed to each pack's own runLocal.sh. The
# onboarding_cli_proxy pack needs one: it puts its proxy on BASE_PORT+98, and
# the host must resolve vip.ve.atsign.zone to 127.0.0.1.
#
# AT_CLIENT_SDK_DIR names an at_client_sdk clone (default: at_client_sdk
# beside this checkout). AT_CLIENT_SDK_REF names the commit to test (default:
# origin/trunk, fetched first). The packs run from a detached worktree of that
# commit, removed afterwards; the clone's working tree and branches are never
# touched. A commit whose pack runners do not take VIRTUALENV_IMAGE, and name
# their compose project after the base port, is refused, since it would run
# an image this script did not build, or share containers with another run.
# With no BASE_PORT, every pack uses its default project name and ports, as
# any other default-port run of that pack does.
#
# buildve.sh builds the atServer image under this checkout's own tag, which
# is passed to each pack as VIRTUALENV_IMAGE; at_virtual_env:local is never
# touched. HOME points at a scratch directory for the run, and PUB_CACHE and
# DOCKER_CONFIG keep their values.
#
# Each pack runs in its own process group, with stdin from /dev/null. An
# interrupt, TERM, HUP or ALRM stops the running pack, and every container a
# pack left running is taken down before the worktree is removed; a further
# signal during that cleanup is reported and does not cut it short. A signal
# during the build takes effect once the build ends. KILL ends the runner
# alone, leaving the running pack, its containers and the worktree behind.
#
# Exits non-zero if any pack fails, after running the rest. When
# GITHUB_STEP_SUMMARY is set, the at_client_sdk commit, the atServer build,
# each pack's result and any stopping signal are appended to it as each
# becomes known.

cd "$(dirname -- "$0")/../.."
repoDir=$(pwd)

# Appends lines to the job summary, when there is one.
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  VIRTUALENV_BASE_PORT="$1"
  shift
fi
basePort="${VIRTUALENV_BASE_PORT:-}"
if [[ -n "$basePort" && ! "$basePort" =~ ^[0-9]+$ ]]; then
  echo "*** Not a base port: ${basePort}" >&2
  exit 2
fi
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
  if [[ "$pack" == onboarding_cli_proxy && -z "$basePort" ]]; then
    echo "*** The onboarding_cli_proxy pack needs a BASE_PORT" >&2
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
  fetchRef="${sdkRef#origin/}"
  fetchRef="${fetchRef%%[~^]*}"
  echo "*** Fetching origin ${fetchRef} in ${sdkDir}"
  git -C "$sdkDir" fetch origin "$fetchRef" ||
    { sleep 2 && git -C "$sdkDir" fetch origin "$fetchRef"; }
fi
sdkCommit=$(git -C "$sdkDir" rev-parse --verify "${sdkRef}^{commit}")
summary "- at_client_sdk ${sdkCommit}"

for pack in "${packs[@]}"; do
  runner="tests/$(packDir "$pack")/runLocal.sh"
  runnerText=$(git -C "$sdkDir" show "${sdkCommit}:${runner}" || true)
  if [[ "$runnerText" != *'${VIRTUALENV_IMAGE:-'* ||
    "$runnerText" != *COMPOSE_PROJECT_NAME* ]]; then
    echo "*** at_client_sdk ${sdkCommit}: ${runner} does not take VIRTUALENV_IMAGE and name its compose project" >&2
    exit 2
  fi
done

source "${repoDir}/tools/build_virtual_environment/live_rig.sh"
live_rig_lock "$repoDir" || exit 1
image=$(live_rig_image "$repoDir")

tmpRoot="${TMPDIR:-/tmp}"
runDir=$(mktemp -d "${tmpRoot%/}/client_checks.XXXXXX")
runDirPhysical=$(cd "$runDir" && pwd -P)
sdkWorktree="${runDir}/at_client_sdk"
packPid=""

# Stops the running pack's process group, giving it 30 seconds to tidy up.
stopPack() {
  if [[ -z "$packPid" ]]; then
    return 0
  fi
  if kill -0 -- "-${packPid}" 2>/dev/null; then
    kill -TERM -- "-${packPid}" || true
    kill -CONT -- "-${packPid}" || true
    local waited=0
    while kill -0 -- "-${packPid}" 2>/dev/null && ((waited < 30)); do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 -- "-${packPid}" 2>/dev/null; then
      kill -KILL -- "-${packPid}" || true
    fi
  fi
  packPid=""
}

# Takes down every compose project whose files are in this run's worktree.
downPackContainers() {
  local projects project
  projects=$(docker ps -a --format \
    '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}' |
    while IFS='|' read -r project dir; do
      if [[ -n "$project" &&
        ("$dir" == "${runDir}/"* || "$dir" == "${runDirPhysical}/"*) ]]; then
        echo "$project"
      fi
    done | sort -u) || true
  for project in $projects; do
    echo "*** Taking down ${project}, which a pack left running"
    perl -e 'alarm 120; exec @ARGV' -- \
      docker compose -p "$project" down --remove-orphans || true
  done
}

cleanup() {
  trap 'echo "*** Still cleaning up" >&2' INT TERM HUP ALRM
  stopPack
  downPackContainers
  if [[ -d "$sdkWorktree" ]]; then
    git -C "$sdkDir" worktree remove --force "$sdkWorktree" || true
  fi
  rm -rf "$runDir"
}
onSignal() {
  trap 'echo "*** Still cleaning up" >&2' INT TERM HUP ALRM
  summary "- stopped by a signal (exit $1)"
  stopPack
  exit "$1"
}
trap cleanup EXIT
trap 'onSignal 130' INT
trap 'onSignal 143' TERM
trap 'onSignal 129' HUP
trap 'onSignal 142' ALRM

echo "*** Checking out at_client_sdk ${sdkCommit} in ${sdkWorktree}"
git -C "$sdkDir" worktree add --detach "$sdkWorktree" "$sdkCommit"

echo "*** Building ${image} from ${repoDir}"
bash "${repoDir}/tools/build_virtual_environment/buildve.sh" -t "$image"
built=$(docker image inspect "$image" --format \
  '{{index .Config.Labels "com.atsign.ve.revision"}} tree {{index .Config.Labels "com.atsign.ve.tree"}} dirty={{index .Config.Labels "com.atsign.ve.dirty"}}')
summary "- at_server ${built}, as ${image}"

export PUB_CACHE="${PUB_CACHE:-${HOME}/.pub-cache}"
export DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"
mkdir -p "${runDir}/home"
export HOME="${runDir}/home"
export VIRTUALENV_IMAGE="$image"

results=()
failed=0
for pack in "${packs[@]}"; do
  echo "*** Running at_client_sdk's ${pack} pack against ${image}"
  set -m
  (cd "${sdkWorktree}/tests/$(packDir "$pack")" &&
    exec ./runLocal.sh ${basePort:+"$basePort"} </dev/null) &
  packPid=$!
  set +m
  if wait "$packPid"; then
    status=0
  else
    status=$?
  fi
  packPid=""
  downPackContainers
  if [[ $status -eq 0 ]]; then
    results+=("${pack}: passed")
  else
    results+=("${pack}: FAILED (exit ${status})")
    failed=1
  fi
  summary "- ${results[${#results[@]} - 1]}"
done

echo "*** at_client_sdk ${sdkCommit} against ${image}, at_server ${built}:"
printf '***   %s\n' "${results[@]}"
exit "$failed"

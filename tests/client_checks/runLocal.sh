#!/usr/bin/env bash
set -euo pipefail

# Runs at_client_sdk's live packs against an atServer built from this
# checkout, so an atServer change that breaks the reference SDK shows up
# before it reaches trunk. The packs' other dependencies, this repo's
# at_persistence packages among them, come from pub.dev.
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
# onboarding_cli_proxy pack needs one, since it puts its proxy on
# BASE_PORT+98. Every pack dials vip.ve.atsign.zone from the host, so the
# host must resolve it to 127.0.0.1.
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
# DOCKER_CONFIG keep their values. A pack passes only if its runner exits 0
# and every virtualenv container it created ran that image; that checks the
# pack's own containers, not which atServer each test reached.
#
# Each pack runs in its own process group, with stdin from /dev/null. An
# interrupt, TERM, HUP or ALRM stops the running pack, and every container a
# pack left behind is removed before the worktree is. The cleanup ignores a
# further signal; the commands it runs ignore a further interrupt or HUP, and
# each docker call runs in a process group of its own, which a terminal's
# signals do not reach.
# A signal during the build takes effect once the build ends. KILL ends the
# runner alone, leaving the running pack, its containers and the worktree
# behind.
#
# Exits non-zero if any pack fails, after running the rest, and 2 if the run
# is refused. When GITHUB_STEP_SUMMARY is set, a refusal, the at_client_sdk
# commit, the atServer build, each pack's result and any stopping signal are
# appended to it as each becomes known.

cd "$(dirname -- "$0")/../.."
repoDir=$(pwd)

# Appends lines to the job summary, when there is one.
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Refuses the run, saying why.
refuse() {
  echo "*** $1" >&2
  summary "- refused: $1"
  exit 2
}

# Runs a command in a process group of its own, with stdin from /dev/null,
# sending it TERM after [seconds] and KILL ten seconds later.
# NOTE a plain alarm cannot bound docker, which ignores SIGALRM, and an ignored
# SIGINT does not protect it, since it handles SIGINT itself.
bounded() {
  perl -MPOSIX -e '
    my $seconds = shift;
    my $pid = fork() // die "bounded: cannot fork: $!\n";
    if ($pid == 0) {
      setpgrp(0, 0);
      open(STDIN, "<", "/dev/null") or die "bounded: cannot read /dev/null: $!\n";
      $SIG{TERM} = "DEFAULT";
      exec(@ARGV) or die "bounded: cannot run $ARGV[0]: $!\n";
    }
    $SIG{ALRM} = sub {
      kill("TERM", $pid);
      $SIG{ALRM} = sub { kill("KILL", $pid) };
      alarm(10);
    };
    alarm($seconds);
    waitpid($pid, 0);
    exit(WIFEXITED($?) ? WEXITSTATUS($?) : 128 + WTERMSIG($?));
  ' "$@"
}

if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  VIRTUALENV_BASE_PORT="$1"
  shift
fi
basePort="${VIRTUALENV_BASE_PORT:-}"
if [[ -n "$basePort" && ! "$basePort" =~ ^[0-9]+$ ]]; then
  refuse "Not a base port: ${basePort}"
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
    refuse "Unknown pack '$pack': use functional, e2e, onboarding_cli or onboarding_cli_proxy"
  fi
  if [[ "$pack" == onboarding_cli_proxy && -z "$basePort" ]]; then
    refuse "The onboarding_cli_proxy pack needs a BASE_PORT"
  fi
done

sdkDir="${AT_CLIENT_SDK_DIR:-${repoDir}/../at_client_sdk}"
sdkRef="${AT_CLIENT_SDK_REF:-origin/trunk}"
if ! git -C "$sdkDir" rev-parse --git-dir >/dev/null; then
  refuse "No at_client_sdk clone at ${sdkDir}; set AT_CLIENT_SDK_DIR"
fi
if [[ "$sdkRef" == origin/* ]]; then
  fetchRef="${sdkRef#origin/}"
  fetchRef="${fetchRef%%[~^]*}"
  echo "*** Fetching origin ${fetchRef} in ${sdkDir}"
  git -C "$sdkDir" fetch origin "$fetchRef" ||
    { sleep 2 && git -C "$sdkDir" fetch origin "$fetchRef"; }
fi
sdkCommit=$(git -C "$sdkDir" rev-parse --verify "${sdkRef}^{commit}") ||
  refuse "No commit ${sdkRef} in ${sdkDir}"
summary "- at_client_sdk ${sdkCommit}"

for pack in "${packs[@]}"; do
  runner="tests/$(packDir "$pack")/runLocal.sh"
  runnerText=$(git -C "$sdkDir" show "${sdkCommit}:${runner}" || true)
  if [[ "$runnerText" != *'${VIRTUALENV_IMAGE:-'* ||
    "$runnerText" != *COMPOSE_PROJECT_NAME* ]]; then
    refuse "at_client_sdk ${sdkCommit}: ${runner} does not take VIRTUALENV_IMAGE and name its compose project"
  fi
done

source "${repoDir}/tools/build_virtual_environment/live_rig.sh"
if ! live_rig_lock "$repoDir"; then
  summary "- could not take the live-rig lock"
  exit 1
fi
image=$(live_rig_image "$repoDir")

tmpRoot="${TMPDIR:-/tmp}"
runDir=$(mktemp -d "${tmpRoot%/}/client_checks.XXXXXX")
runDir=$(cd "$runDir" && pwd -P)
sdkWorktree="${runDir}/at_client_sdk"
packPid=""
launching=""
bgBefore="${!:-}"
eventsPid=""
explained=""

# Stops the running pack's process group, giving it 30 seconds to tidy up.
stopPack() {
  local pid="$packPid"
  # NOTE a signal between the pack's launch and the line recording its pid
  # finds packPid empty while $! already names the pack.
  if [[ -z "$pid" && -n "$launching" && "${!:-}" != "$bgBefore" ]]; then
    pid=$!
  fi
  if [[ -z "$pid" ]]; then
    return 0
  fi
  if kill -0 -- "-${pid}" 2>/dev/null; then
    kill -TERM -- "-${pid}" || true
    kill -CONT -- "-${pid}" || true
    local waited=0
    while kill -0 -- "-${pid}" 2>/dev/null && ((waited < 30)); do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 -- "-${pid}" 2>/dev/null; then
      kill -KILL -- "-${pid}" || true
    fi
  fi
  packPid=""
}

# Records the compose directory, service and image of each container created
# from two minutes before [now] (a Unix time) on, into [log].
# NOTE the margin is for the docker daemon's clock, which can lag the host's.
watchContainers() {
  docker events --since "$(($1 - 120))" --filter type=container --filter event=create \
    --format '{{index .Actor.Attributes "com.docker.compose.project.working_dir"}}|{{index .Actor.Attributes "com.docker.compose.service"}}|{{.Actor.Attributes.image}}' \
    > "$2" &
  eventsPid=$!
}

stopWatching() {
  if [[ -n "$eventsPid" ]]; then
    if kill -0 "$eventsPid" 2>/dev/null; then
      kill -TERM "$eventsPid" || true
    fi
    wait "$eventsPid" || true
    eventsPid=""
  fi
}

# Says whether the virtualenv containers recorded in [log] from the pack
# directory [packRoot] all ran this run's image, and there was at least one.
ranImage() {
  local packRoot="$2" dir service used seen=""
  while IFS='|' read -r dir service used; do
    if [[ ("$dir" == "$packRoot" || "$dir" == "$packRoot"/*) &&
      "$service" == *virtualenv ]]; then
      if [[ "$used" != "$image" ]]; then
        return 1
      fi
      seen=1
    fi
  done < "$1"
  [[ -n "$seen" ]]
}

# Removes every container whose compose files are in this run's worktree, then
# whichever of their compose networks no container still uses.
downPackContainers() {
  local id name project dir ids=() projects=()
  while IFS='|' read -r id name project dir; do
    if [[ "$dir" == "${runDir}/"* ]]; then
      echo "*** Removing ${name}, which a pack left behind"
      ids+=("$id")
      projects+=("$project")
    fi
  done < <(bounded 60 docker ps -a --format \
    '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}' || true)
  if [[ ${#ids[@]} -eq 0 ]]; then
    return 0
  fi
  bounded 120 docker rm -f "${ids[@]}" || true
  for project in $(printf '%s\n' "${projects[@]}" | sort -u); do
    bounded 60 docker network prune -f \
      --filter "label=com.docker.compose.project=${project}" || true
  done
}

cleanup() {
  local status=$?
  set +e
  trap '' INT TERM HUP ALRM PIPE
  if [[ $status -ne 0 && -z "$explained" ]]; then
    summary "- ended early (exit ${status})"
  fi
  stopPack
  stopWatching
  downPackContainers
  if [[ -d "$sdkWorktree" ]]; then
    git -C "$sdkDir" worktree remove --force "$sdkWorktree"
  fi
  rm -rf "$runDir"
}
onSignal() {
  set +e
  trap '' INT TERM HUP ALRM PIPE
  summary "- stopped by a signal (exit $1)"
  explained=1
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
if ! bash "${repoDir}/tools/build_virtual_environment/buildve.sh" -t "$image"; then
  summary "- the atServer build failed"
  explained=1
  exit 1
fi
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
  containersLog="${runDir}/containers.${pack}"
  watchContainers "$(date +%s)" "$containersLog"
  bgBefore=$!
  launching=1
  set -m
  (cd "${sdkWorktree}/tests/$(packDir "$pack")" &&
    exec ./runLocal.sh ${basePort:+"$basePort"} </dev/null) &
  packPid=$!
  launching=""
  set +m
  if wait "$packPid"; then
    status=0
  else
    status=$?
  fi
  packPid=""
  stopWatching
  downPackContainers
  if [[ $status -ne 0 ]]; then
    results+=("${pack}: FAILED (exit ${status})")
    failed=1
  elif ! ranImage "$containersLog" "${sdkWorktree}/tests/$(packDir "$pack")"; then
    results+=("${pack}: FAILED (its virtualenv did not run ${image})")
    failed=1
  else
    results+=("${pack}: passed")
  fi
  summary "- ${results[${#results[@]} - 1]}"
done

explained=1
echo "*** at_client_sdk ${sdkCommit} against ${image}, at_server ${built}:"
printf '***   %s\n' "${results[@]}"
exit "$failed"

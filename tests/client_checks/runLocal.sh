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
# commit, removed afterwards; the clone's working tree and local branches are
# never touched. A commit whose pack runners do not take VIRTUALENV_IMAGE, and
# name their compose project after the base port, is refused, since it would
# run an image this script did not build, or share containers with another
# run. With no BASE_PORT, every pack uses its default project name and ports,
# as any other default-port run of that pack does. With one, a pack whose
# compose project already has containers, another run's or ones a stopped run
# left behind, fails without starting. That is checked once, as the pack
# starts, so two runs started at the same moment on one base can both start.
#
# buildve.sh builds the atServer image under this checkout's own tag, which
# is passed to each pack as VIRTUALENV_IMAGE; at_virtual_env:local is never
# touched. HOME points at a scratch directory for the run, and PUB_CACHE and
# DOCKER_CONFIG keep their values. A pack passes only if its runner exits 0
# within CLIENT_CHECKS_PACK_MINUTES (default 45), and every virtualenv
# container it created ran that image, by id where compose records it, in the
# compose project named after the base port when there is one; that checks
# the pack's own containers, not which atServer each test reached.
#
# Each pack runs in its own process group, with stdin from /dev/null, and
# whatever is still running in that group once the pack's runner exits is
# stopped. An interrupt, TERM, HUP or ALRM stops the running pack, and every
# container a pack left behind, then each of their networks no running
# container uses, is removed before the worktree is. The cleanup ignores a
# further signal, and so do the commands it runs: each docker call runs in a
# process group of its own, which a terminal's signals do not reach. A signal
# during the build takes effect once the build ends. KILL ends the runner
# alone, leaving the running pack, its containers and the worktree behind.
#
# Exits non-zero if any pack fails, after running the rest, and 2 if the run
# is refused. When GITHUB_STEP_SUMMARY is set, the runner appends to it, as
# each becomes known, what it is testing, each pack's result, and why the run
# was refused, stopped or ended early.

cd "$(dirname -- "$0")/../.."
repoDir=$(pwd)
packMinutes="${CLIENT_CHECKS_PACK_MINUTES:-45}"

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

# Run as `perl -MPOSIX -e "$inOwnGroup" SECONDS OWNER COMMAND...`, it runs
# COMMAND in a process group of its own, with stdin from /dev/null, and exits
# with its status. COMMAND gets TERM, then KILL ten seconds later, once
# SECONDS have passed (never, if 0), once its parent is no longer the process
# OWNER (never, if 0), or when the helper gets INT, TERM, HUP or ALRM, except a
# signal it was started ignoring.
# NOTE docker needs this: it ignores SIGALRM, so a plain alarm cannot bound
# it, and it handles SIGINT itself, so an ignored SIGINT does not protect it.
inOwnGroup='
    my ($seconds, $owner, @command) = @ARGV;
    my $pid = fork() // die "inOwnGroup: cannot fork: $!\n";
    if ($pid == 0) {
      setpgrp(0, 0);
      open(STDIN, "<", "/dev/null") or die "inOwnGroup: cannot read /dev/null: $!\n";
      $SIG{TERM} = "DEFAULT";
      exec(@command) or die "inOwnGroup: cannot run $command[0]: $!\n";
    }
    my $stopAt = 0;
    for my $signal (qw(INT TERM HUP ALRM)) {
      next if ($SIG{$signal} // "") eq "IGNORE";
      $SIG{$signal} = sub { $stopAt ||= time };
    }
    my $deadline = $seconds > 0 ? time + $seconds : 0;
    my ($termAt, $killed) = (0, 0);
    while (waitpid($pid, WNOHANG) == 0) {
      $stopAt ||= time if ($deadline && time >= $deadline) || ($owner && getppid() != $owner);
      if ($stopAt && !$termAt) {
        kill("TERM", $pid);
        $termAt = time;
      }
      if ($termAt && !$killed && time >= $termAt + 10) {
        kill("KILL", $pid);
        $killed = 1;
      }
      select(undef, undef, undef, 0.2);
    }
    exit(WIFEXITED($?) ? WEXITSTATUS($?) : 128 + WTERMSIG($?));
'

# Runs a command as inOwnGroup does, stopping it after [seconds].
bounded() {
  local seconds="$1"
  shift
  perl -MPOSIX -e "$inOwnGroup" "$seconds" 0 "$@"
}

if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  VIRTUALENV_BASE_PORT="$1"
  shift
fi
basePort="${VIRTUALENV_BASE_PORT:-}"
if [[ -n "$basePort" && ! "$basePort" =~ ^[0-9]+$ ]]; then
  refuse "Not a base port: ${basePort}"
fi
if [[ ! "$packMinutes" =~ ^[1-9][0-9]*$ ]]; then
  refuse "Not a number of minutes: CLIENT_CHECKS_PACK_MINUTES=${packMinutes}"
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
  fetched=""
  for delay in 0 2 5; do
    sleep "$delay"
    if git -C "$sdkDir" fetch origin "$fetchRef"; then
      fetched=1
      break
    fi
  done
  if [[ -z "$fetched" ]]; then
    refuse "Could not fetch origin ${fetchRef} in ${sdkDir}"
  fi
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
eventsPid=""
watchdogPid=""
explained=""
inCleanup=""
exitStatus=0

# Stops whatever is running in the pack's process group, giving it 30 seconds
# to tidy up.
stopPack() {
  local pid="$packPid"
  # NOTE a signal between the pack's launch and the line recording its pid
  # finds packPid empty while $! already names the pack.
  if [[ -z "$pid" && -n "$launching" && "${!:-}" != "$eventsPid" ]]; then
    pid=$!
  fi
  if [[ -z "$pid" ]]; then
    return 0
  fi
  if kill -0 -- "-${pid}" 2>/dev/null; then
    echo "*** Stopping what is still running in process group ${pid}"
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

# Sends TERM to process group [group] after [seconds], and KILL ten seconds
# later, creating [marker] first. It stops by itself once this shell has gone.
startWatchdog() {
  perl -e '
    my ($seconds, $group, $owner, $marker) = @ARGV;
    $SIG{$_} = "IGNORE" for qw(INT HUP ALRM);
    my $deadline = time + $seconds;
    while (time < $deadline) {
      exit(0) if getppid() != $owner;
      sleep(1);
    }
    open(my $created, ">", $marker) and close($created);
    kill("TERM", -$group);
    sleep(10);
    kill("KILL", -$group);
  ' "$1" "$2" "$$" "$3" &
  watchdogPid=$!
}

stopWatchdog() {
  if [[ -n "$watchdogPid" ]]; then
    if kill -0 "$watchdogPid" 2>/dev/null; then
      kill -TERM "$watchdogPid" || true
    fi
    wait "$watchdogPid" || true
    watchdogPid=""
  fi
}

# Records the compose directory, service, project, image and image id of each
# container created from now on, into [log], until stopWatching or until this
# shell has gone.
watchContainers() {
  local since
  since=$(bounded 30 docker system info --format '{{.SystemTime}}')
  perl -MPOSIX -e "$inOwnGroup" 0 "$$" docker events --since "$since" --filter type=container --filter event=create \
    --format '{{index .Actor.Attributes "com.docker.compose.project.working_dir"}}|{{index .Actor.Attributes "com.docker.compose.service"}}|{{index .Actor.Attributes "com.docker.compose.project"}}|{{.Actor.Attributes.image}}|{{index .Actor.Attributes "com.docker.compose.image"}}' \
    > "$1" &
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
# directory [packRoot] all ran this run's image, in compose project [project]
# when that is not empty, and there was at least one. If not, notAsBuilt says
# why; idUnchecked is set when compose recorded no image id to compare.
ranAsBuilt() {
  local packRoot="$2" project="$3" dir service usedProject used usedId seen=""
  while IFS='|' read -r dir service usedProject used usedId; do
    if [[ ("$dir" == "$packRoot" || "$dir" == "$packRoot"/*) &&
      "$service" == *virtualenv ]]; then
      if [[ "$used" != "$image" || (-n "$usedId" && "$usedId" != "$imageId") ]]; then
        notAsBuilt="its virtualenv did not run ${image}"
        return 1
      fi
      if [[ -n "$project" && "$usedProject" != "$project" ]]; then
        notAsBuilt="its virtualenv ran in compose project ${usedProject}, not ${project}"
        return 1
      fi
      if [[ -z "$usedId" ]]; then
        idUnchecked=1
      fi
      seen=1
    fi
  done < "$1"
  if [[ -z "$seen" ]]; then
    notAsBuilt="it created no virtualenv container"
    return 1
  fi
}

# Says whether a container outside this run's worktree is in compose project
# [project], naming each such container and its compose directory in inUseBy.
projectInUse() {
  local name dir
  inUseBy=""
  while IFS='|' read -r name dir; do
    if [[ "$dir" != "${runDir}/"* ]]; then
      inUseBy="${inUseBy:+${inUseBy}, }${name} from ${dir:-no compose directory}"
    fi
  done < <(bounded 60 docker ps -a --filter "label=com.docker.compose.project=$1" \
    --format '{{.Names}}|{{.Label "com.docker.compose.project.working_dir"}}' || true)
  [[ -n "$inUseBy" ]]
}

# Prints the at_ packages the worktree's pubspec.lock took from pub.dev, with
# their versions.
hostedAtPackages() {
  awk '
    /^  [a-z0-9_]+:$/ { name = substr($1, 1, length($1) - 1); source = "" }
    /^    source: / { source = $2 }
    /^    version: / {
      version = $2
      gsub(/"/, "", version)
      if (name ~ /^at_/ && source == "hosted") print name " " version
    }
  ' "$1" | paste -sd ',' - | sed 's/,/, /g'
}

# Removes every container whose compose files are in this run's worktree,
# then each of their networks that no running container uses. With
# [settle], it looks again three seconds later, for a container whose
# creation was in flight.
downPackContainers() {
  local pass id name dir ids networks
  for pass in 1 2; do
    ids=()
    while IFS='|' read -r id name dir; do
      if [[ "$dir" == "${runDir}/"* ]]; then
        echo "*** Removing ${name}, which a pack left behind"
        ids+=("$id")
      fi
    done < <(bounded 60 docker ps -a --format \
      '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project.working_dir"}}' || true)
    if [[ ${#ids[@]} -gt 0 ]]; then
      networks=()
      while read -r id; do
        if [[ -n "$id" ]]; then
          networks+=("$id")
        fi
      done < <(bounded 60 docker inspect --format \
        '{{range $name, $network := .NetworkSettings.Networks}}{{if $network.NetworkID}}{{println $network.NetworkID}}{{else}}{{println $name}}{{end}}{{end}}' \
        "${ids[@]}" | sort -u || true)
      bounded 120 docker rm -f "${ids[@]}" || true
      if [[ ${#networks[@]} -gt 0 ]]; then
        for id in "${networks[@]}"; do
          bounded 60 docker network rm "$id" || true
        done
      fi
    fi
    if [[ -z "${1:-}" || $pass -eq 2 ]]; then
      break
    fi
    sleep 3
  done
}

# Ends the run with [status], ignoring signals from here on so that the
# cleanup runs to its end.
finish() {
  trap '' INT TERM HUP ALRM PIPE
  exit "$1"
}

cleanup() {
  local settle=""
  set +e
  trap '' INT TERM HUP ALRM PIPE
  if [[ $exitStatus -ne 0 && -z "$explained" ]]; then
    summary "- ended early (exit ${exitStatus})"
  fi
  if [[ -n "$packPid" || -n "$launching" ]]; then
    settle=settle
  fi
  stopPack
  stopWatchdog
  stopWatching
  downPackContainers "$settle"
  if [[ -d "$sdkWorktree" ]]; then
    git -C "$sdkDir" worktree remove --force "$sdkWorktree"
  fi
  rm -rf "$runDir"
}
onSignal() {
  if [[ -n "$inCleanup" ]]; then
    return 0
  fi
  set +e
  trap '' INT TERM HUP ALRM PIPE
  echo "*** Stopping, and cleaning up; a further signal is ignored" >&2
  summary "- stopped by a signal (exit $1)"
  explained=1
  finish "$1"
}
trap 'exitStatus=$?; inCleanup=1; cleanup' EXIT
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
  finish 1
fi
built=$(docker image inspect "$image" --format \
  '{{index .Config.Labels "com.atsign.ve.revision"}} tree {{index .Config.Labels "com.atsign.ve.tree"}} dirty={{index .Config.Labels "com.atsign.ve.dirty"}}')
imageId=$(docker image inspect "$image" --format '{{.Id}}')
summary "- at_server ${built}, as ${image}"

export PUB_CACHE="${PUB_CACHE:-${HOME}/.pub-cache}"
export DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"
mkdir -p "${runDir}/home"
export HOME="${runDir}/home"
export VIRTUALENV_IMAGE="$image"

results=()
failed=0
hostedNamed=""
for pack in "${packs[@]}"; do
  project="${basePort:+$(packDir "$pack")-${basePort}}"
  if [[ -n "$project" ]] && projectInUse "$project"; then
    results+=("${pack}: FAILED (compose project ${project} is in use, by another run or one left behind: ${inUseBy})")
    failed=1
    summary "- ${results[${#results[@]} - 1]}"
    continue
  fi
  echo "*** Running at_client_sdk's ${pack} pack against ${image}"
  containersLog="${runDir}/containers.${pack}"
  timedOut="${runDir}/timed-out.${pack}"
  watchContainers "$containersLog"
  launching=1
  set -m
  (cd "${sdkWorktree}/tests/$(packDir "$pack")" &&
    exec ./runLocal.sh ${basePort:+"$basePort"} </dev/null) &
  packPid=$!
  launching=""
  set +m
  startWatchdog $((packMinutes * 60)) "$packPid" "$timedOut"
  if wait "$packPid"; then
    status=0
  else
    status=$?
  fi
  stopWatchdog
  stopPack
  stopWatching
  downPackContainers
  if [[ -z "$hostedNamed" && -f "${sdkWorktree}/pubspec.lock" ]]; then
    summary "- from pub.dev: $(hostedAtPackages "${sdkWorktree}/pubspec.lock")"
    hostedNamed=1
  fi
  notAsBuilt=""
  idUnchecked=""
  if [[ -f "$timedOut" ]]; then
    results+=("${pack}: FAILED (stopped at its ${packMinutes}-minute limit)")
    failed=1
  elif [[ $status -ne 0 ]]; then
    results+=("${pack}: FAILED (exit ${status})")
    failed=1
  elif ! ranAsBuilt "$containersLog" "${sdkWorktree}/tests/$(packDir "$pack")" "$project"; then
    results+=("${pack}: FAILED (${notAsBuilt})")
    failed=1
  elif [[ -n "$idUnchecked" ]]; then
    results+=("${pack}: passed (compose recorded no image id, so only the tag was checked)")
  else
    results+=("${pack}: passed")
  fi
  summary "- ${results[${#results[@]} - 1]}"
done

explained=1
echo "*** at_client_sdk ${sdkCommit} against ${image}, at_server ${built}:"
printf '***   %s\n' "${results[@]}"
finish "$failed"

# Sourced by buildve.sh and the live-pack runners, so that runs from separate
# checkouts or worktrees can run side by side on separate VIRTUALENV_BASE_PORT
# blocks. Bash 3.2 compatible: the functional runners run under /bin/bash.

# Holds a lock on the checkout at [repoDir] for as long as the calling shell
# lives. A build writes into the checkout and the e2e runner rewrites files in
# it, so two live runs in one checkout take turns; separate worktrees do not
# wait on each other. A caller already holding the lock (buildve.sh under a
# runner) proceeds at once.
live_rig_lock() {
  local repoDir="$1"
  local lockFile
  lockFile="$(git -C "$repoDir" rev-parse --absolute-git-dir)/at_server_live_rig.lock" || return 1
  if [[ "${AT_SERVER_LIVE_RIG_LOCK:-}" == "$lockFile" ]]; then
    return 0
  fi
  local fifo
  fifo="$(mktemp -u "${TMPDIR:-/tmp}/live_rig_lock.XXXXXX")"
  mkfifo "$fifo" || return 1
  # NOTE the kernel releases a flock when its holder dies, even by kill -9, so
  # no stale lock can outlive a run. The holder waits for this shell to exit.
  perl -e '
    use strict;
    use warnings;
    use Fcntl qw(:flock);
    my ($file, $owner) = @ARGV;
    $SIG{$_} = "IGNORE" for qw(INT TERM HUP);
    open(my $fh, "+>>", $file) or die "live_rig_lock: cannot open $file: $!\n";
    my ($told, $polls) = (0, 0);
    until (flock($fh, LOCK_EX | LOCK_NB)) {
      exit 1 if getppid() != $owner;
      unless ($told) {
        seek($fh, 0, 0);
        my $holder = <$fh> // "";
        # NOTE a new holder takes the lock before it writes its pid, so an
        # empty file is re-read for a few polls before the holder is unnamed.
        if ($holder ne "" || ++$polls >= 5) {
          $holder = "an unknown process\n" if $holder eq "";
          print STDERR "Waiting for the live-rig lock $file, held by $holder";
          $told = 1;
        }
      }
      sleep 1;
    }
    truncate($fh, 0);
    syswrite($fh, "pid $owner\n");
    $| = 1;
    print "locked\n";
    close(STDOUT);
    sleep 1 while getppid() == $owner;
  ' "$lockFile" "$$" > "$fifo" &
  local reply=""
  read -r reply < "$fifo" || true
  rm -f "$fifo"
  if [[ "$reply" != "locked" ]]; then
    echo "live_rig_lock: could not lock $lockFile" >&2
    return 1
  fi
  export AT_SERVER_LIVE_RIG_LOCK="$lockFile"
}

# The name of a pack's virtualenv container: [stem] on the default ports, and
# [stem]_<base> on a shifted base, so runs on different bases never stop each
# other's containers.
live_rig_container_name() {
  echo "$1${VIRTUALENV_BASE_PORT:+_${VIRTUALENV_BASE_PORT}}"
}

# The VE image tag for the checkout at [repoDir], so a build from one checkout
# never replaces the image another is about to run.
live_rig_image() {
  echo "at_virtual_env:local-$(printf '%s' "$1" | git hash-object --stdin | cut -c1-12)"
}

# Builds the VE from the checkout at [repoDir] as [image], then also tags it
# at_virtual_env:local, the image at_client_sdk's local live packs run.
live_rig_build_ve() {
  local repoDir="$1" image="$2"
  bash "${repoDir}/tools/build_virtual_environment/buildve.sh" -t "$image" || return 1
  docker tag "$image" at_virtual_env:local
}

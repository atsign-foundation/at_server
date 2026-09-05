#!/bin/bash
#
# Runs the functional pack against a secondary in DUAL persistence mode
# (Hive primary + SQLite secondary, every write mirrored), then compares each
# hosted atSign's Hive and SQLite DB sets for byte-identity.
#
#   ./runDualCompare.sh [BASE_PORT]
#
# The root/secondary binaries are always recompiled, through buildve.sh, which
# compiles, copies and builds as one act. `--build` used to make that optional
# and is now accepted and ignored: reusing binaries staged by a previous run
# produced an image whose provenance labels named THIS tree while its contents
# came from whatever built them last, which is the lie those labels exist to
# prevent.
#
# Optional VE base port, as in runLocal.sh: set VIRTUALENV_BASE_PORT (env) or
# pass it as a positional argument. Shifts the whole VE port range —
# atDirectory to BASE, atServers to BASE+1.., Redis to BASE+99 — so this run
# coexists with anything squatting the default 64/443/6379/25000+ ports. The
# harness reads VIRTUALENV_BASE_PORT too (config_util, the readiness checks).
#
# Exit: 0 = pack passed AND every atSign's Hive == SQLite; non-zero otherwise.

set -uo pipefail
cd "$(dirname -- "$0")"; cd ../../; repoDir=$(pwd)
CONT=at_server_func_cont
PERSIST_PKG="${repoDir}/packages/at_persistence_secondary_server"

for arg in "$@"; do
  case "$arg" in
    # Accepted and ignored. The compile is unconditional now: buildve.sh
    # compiles, copies and builds as one act, because skipping the compile
    # produced an image whose labels named this tree while its binaries came
    # from whatever built them last. Kept as a no-op rather than an error so
    # an existing invocation does not start failing.
    --build) echo "note: --build is now the default and is ignored" ;;
    *) VIRTUALENV_BASE_PORT="$arg" ;;
  esac
done
VIRTUALENV_BASE_PORT="${VIRTUALENV_BASE_PORT:-}"
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

# buildve.sh compiles, copies AND builds, and it is the only builder that
# LABELS the image — an unlabelled VE is indistinguishable from one built by
# anybody else, which is why a cross-repo run against one proves nothing.
#
# ⚠️ Note this differs from the previous behaviour: the compile used to be
# skippable with --build, and is not any more. Skipping it produced an image
# whose labels named this tree while its binaries came from whatever built
# them last — precisely the provenance lie the labels exist to stop.
echo "== build VE image (with libsqlite3) =="
bash "${repoDir}/tools/build_virtual_environment/buildve.sh" || exit 1

echo "== run container in DUAL mode =="
# No --rm: the DB snapshot is taken from the *stopped* container, so it has to
# survive `docker stop`. It is removed at the end (and here, in case a previous
# run left one behind).
docker rm -f $CONT 2>/dev/null
docker run -d --name $CONT \
  -e testingMode="true" -e httpsEnabled="true" -e persistenceBackend="dual" \
  $veEnvArgs $vePortArgs \
  at_virtual_env:local $veCmd || exit 1

echo "== readiness + keys =="
cd "${repoDir}/tests/at_functional_test"
dart run test/check_docker_readiness.dart || { docker rm -f $CONT; exit 1; }
dart run test/check_root_server_readiness.dart || { docker rm -f $CONT; exit 1; }
( cd "${repoDir}/tools/build_virtual_environment/install_PKAM_Keys" && \
  dart pub get && dart bin/install_PKAM_Keys.dart ) || { docker rm -f $CONT; exit 1; }
dart run test/check_test_env.dart || { docker rm -f $CONT; exit 1; }

echo "== run functional pack (dual mode) =="
dart run test --concurrency=1
PACK_RC=$?
echo "functional pack rc=$PACK_RC"

echo "== discover per-atSign databases in $CONT =="
# Enumerate while the container is up (needs docker exec), then stop it before
# copying anything out: with the atServers running, background jobs (stats
# notifications, expiry sweep, compaction) keep writing between the sequential
# copies of the Hive files and atsign.db, so the two halves of one snapshot can
# disagree. `docker cp` works fine on a stopped container, and -t 60 gives
# supervisord room to close every store gracefully rather than be killed
# mid-write.
DB_LIST="$(mktemp)"
docker exec $CONT sh -c "find / -name atsign.db 2>/dev/null" | tr -d '\r' > "$DB_LIST"

echo "== stop container (quiesce before snapshot) =="
docker stop -t 60 $CONT >/dev/null

echo "== compare Hive vs SQLite for each atSign =="
# The VE lays Hive stores out as hive/ commit_log/ access_log/ notification_log/
# (legacy names) and SQLite under storage/sqlite/. The checked-in tool
# tool/dual_compare_ve.dart compares those exact paths; run it from inside the
# persistence package so its package: imports resolve.
( cd "$PERSIST_PKG" && dart pub get >/dev/null 2>&1 ) || true
CMP_FAIL=0
OUT=$(mktemp -d)
while IFS= read -r db; do
  secdir=$(echo "$db" | sed 's|/storage/sqlite/.*||')   # /atsign/secondary/<name>
  atSign=$(basename "$(dirname "$db")")                  # @name
  dest="$OUT/$RANDOM"
  docker cp "$CONT:$secdir/." "$dest" >/dev/null 2>&1
  res=$(cd "$PERSIST_PKG" && dart run tool/dual_compare_ve.dart "$dest" "$atSign" 2>/dev/null | grep -vE "^(SHOUT|INFO|WARNING|FINE)")
  echo "$res"
  rm -rf "$dest"
done < "$DB_LIST" | tee "$OUT/results.txt"
rm -f "$DB_LIST"
IDENT=$(grep -c "^IDENTICAL" "$OUT/results.txt")
TOTAL=$(grep -cE "^(IDENTICAL|MISMATCH)" "$OUT/results.txt")
grep -q "^MISMATCH" "$OUT/results.txt" && CMP_FAIL=1
if [[ $TOTAL -eq 0 ]]; then
  echo "FAIL: no atsign.db found — dual mode did not write SQLite."
  CMP_FAIL=1
fi
echo "atSigns: $TOTAL   IDENTICAL: $IDENT"
rm -rf "$OUT"

echo "== remove container =="
docker rm -f $CONT >/dev/null

echo "======================================================"
echo "functional pack : $([[ $PACK_RC -eq 0 ]] && echo PASS || echo FAIL)"
echo "DB-set identity : $([[ $CMP_FAIL -eq 0 ]] && echo IDENTICAL || echo MISMATCH)"
echo "======================================================"
[[ $PACK_RC -eq 0 && $CMP_FAIL -eq 0 ]] && exit 0 || exit 1

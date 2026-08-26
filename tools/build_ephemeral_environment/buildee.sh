#!/usr/bin/env bash
#
# buildee.sh — build an ephemeral environment (EE) image from THIS working
# tree, rather than pulling the published atsigncompany/ephemeral image.
#
# runee.sh and docker-compose.yaml both name atsigncompany/ephemeral:latest,
# which CI builds from the most recent release tag. Anyone testing a change to
# the atServer or the atDirectory needs an image built from the branch they are
# on, and needs to be able to prove that is what they got.
#
# Usage: buildee.sh [-t <tag>] [-q]
#   -t   image tag to produce (default: at_ephemeral:local)
#   -q   quieter docker output
#
# The image is labelled with the commit it was built from, and the build is
# verified afterwards by reading that label back and confirming the three
# artefacts exist and are executables. See "Why the verification is not
# paranoia" at the bottom.

set -euo pipefail

TAG="at_ephemeral:local"
PROGRESS="auto"

while getopts ":t:qh" opt; do
  case "$opt" in
    t) TAG="$OPTARG" ;;
    q) PROGRESS="plain" ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    \?) echo "buildee.sh: unknown option -$OPTARG" >&2; exit 2 ;;
    :) echo "buildee.sh: -$OPTARG needs an argument" >&2; exit 2 ;;
  esac
done

REPO=$(git rev-parse --show-toplevel)
cd "$REPO"

DOCKERFILE="tools/build_ephemeral_environment/ee_base/Dockerfile"
[[ -f "$DOCKERFILE" ]] || { echo "buildee.sh: no $DOCKERFILE under $REPO" >&2; exit 1; }

REV=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# A dirty tree is legitimate — it is usually the whole point — but the label
# would then name a commit the image does not contain, so say so.
DIRTY=""
if [[ -n "$(git status --porcelain)" ]]; then
  DIRTY=" (working tree has uncommitted changes; the image contains them, the label does not name them)"
fi

echo "Building EE image"
echo "  repo   : $REPO"
echo "  branch : $BRANCH"
echo "  commit : $REV$DIRTY"
echo "  tag    : $TAG"
echo

# The .dockerignore keeps the host's own build outputs out of the context, so
# a compile failure cannot be masked by a stale binary at the same path. Say
# out loud whether they are present, because their absence from the image is
# what the ignore file is buying and a reader should not have to infer it.
for stale in packages/at_root_server/root packages/at_secondary_server/secondary; do
  if [[ -e "$stale" ]]; then
    echo "note: $stale exists on the host and is excluded from the build context"
  fi
done

docker build \
  --progress="$PROGRESS" \
  --label "org.opencontainers.image.revision=$REV" \
  --label "org.opencontainers.image.source=at_server" \
  --label "com.atsign.ee.branch=$BRANCH" \
  -t "$TAG" \
  -f "$DOCKERFILE" \
  . || { echo "buildee.sh: docker build failed" >&2; exit 1; }

echo
echo "Verifying the image is the one this tree just built"

BUILT_REV=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$TAG")
if [[ "$BUILT_REV" != "$REV" ]]; then
  echo "buildee.sh: $TAG reports revision '$BUILT_REV', expected '$REV'." >&2
  echo "            docker reused an image built from another commit." >&2
  exit 1
fi
echo "  revision label matches HEAD"

# `file` is not installed in the slim image, so read the ELF magic directly:
# four bytes, 0x7f 'E' 'L' 'F'. A placeholder or a truncated copy fails this.
docker run --rm "$TAG" /bin/sh -c '
  set -e
  fail=0
  for f in /atsign/root/root /atsign/secondary/secondary /usr/local/bin/at_activate; do
    if [ ! -f "$f" ]; then echo "  MISSING  $f"; fail=1; continue; fi
    magic=$(head -c 4 "$f" | od -An -tx1 | tr -d " \n")
    size=$(wc -c < "$f")
    if [ "$magic" != "7f454c46" ]; then
      echo "  NOT AN EXECUTABLE  $f (magic $magic, $size bytes)"; fail=1; continue
    fi
    echo "  ok  $f  ($size bytes)"
  done
  exit $fail
' || { echo "buildee.sh: the image does not contain the three built artefacts" >&2; exit 1; }

echo
echo "Built $TAG from $BRANCH @ ${REV:0:9}"
echo
echo "Run it with:"
echo "  tools/build_ephemeral_environment/runee.sh <name> <base-port> $TAG"
echo
echo "Remember -e DNS_FQDN=<name> if you are not on a build that carries the"
echo "createConf.sh DNS_FQDN fix: without it every atServer's root_server.url"
echo "is the literal string DNS_FQDN and no atSign can look up any other."

# Why the verification is not paranoia
# -----------------------------------
# Two things this build used to do quietly, both fixed in this tree but not in
# any published image:
#
#   * the RUN chain separated its steps with `;`, so only the last command's
#     exit status reached Docker and a failed compile still produced an image;
#   * there was no .dockerignore, so `COPY . .` carried the host's own
#     packages/at_root_server/root and packages/at_secondary_server/secondary
#     into the build stage at exactly the paths the compile writes. Those are
#     built by tests/at_functional_test/runLocal.sh inside a Linux container,
#     so they are ELF binaries of the right architecture: they run, and the
#     container looks healthy.
#
# The failure mode was therefore an EE that served an atServer from whatever
# branch happened to have been functional-tested last, with nothing anywhere
# saying so. Reading the revision label back is what makes "I built this from
# my branch" a measurement rather than an assumption.

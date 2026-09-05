#!/usr/bin/env bash
#
# buildve.sh — build the virtual environment (VE) image from THIS working
# tree, and LABEL it so that what a run was tested against is a measurement
# rather than an assumption.
#
# Usage: buildve.sh [-t <tag>] [-q]
#   -t   image tag to produce (default: at_virtual_env:local)
#   -q   quieter docker output
#
# Why this exists at all
# ----------------------
# The VE build had no labels of its own, so the image INHERITED the OCI labels
# of atsigncompany/vebase:latest — and those name a commit on trunk while the
# server binaries inside were compiled from whatever working tree ran the
# build. Anyone reading `org.opencontainers.image.revision` to establish
# provenance got a confident, wrong answer. That is worse than no label,
# because a "read the label before you run" discipline walks straight into it.
#
# Two tells distinguish an inherited label from a genuine one, and neither
# needs anything from another repo:
#   * the inherited `org.opencontainers.image.description` reads "Base image
#     for Atsign Virtual Environment" — the labels self-describe as the base's;
#   * the inherited `created` PREDATES the image's own `.Created`, which no
#     genuine label can.
# Both are heuristics, and the second breaks under a partial override — which
# is exactly the shape a fix takes. So provenance is keyed on a namespace no
# upstream base uses: a `com.atsign.ve.*` label cannot be inherited, by
# construction. The OCI values are overridden too, as a courtesy.
#
# A DIRTY tree is legitimate — it is usually the whole point — but a boolean
# marker is not enough. Iterating on a change means build, run, edit, build
# again, all from one commit: `dirty=true` is constant across that sequence
# and cannot tell build N from build N+1. So the marker is a DIGEST of the
# tree state, and the boolean is kept only as the thing a human reads.
#
# The digest MUST cover untracked files. `git diff HEAD | git hash-object
# --stdin` is blind to them, and an untracked file is precisely how source
# reaches a VE binary: the compile mounts the LIVE working tree, and unlike
# the EE build the VE build directory has no .dockerignore at all. Measured on
# a tree with one untracked file, the tracked-only digest reports git's
# EMPTY-BLOB hash — it does not merely miss untracked content, it reports a
# dirty tree as clean.

set -euo pipefail

TAG="at_virtual_env:local"
PROGRESS="auto"

while getopts ":t:qh" opt; do
  case "$opt" in
    t) TAG="$OPTARG" ;;
    q) PROGRESS="plain" ;;
    h) sed -n '2,50p' "$0"; exit 0 ;;
    \?) echo "buildve.sh: unknown option -$OPTARG" >&2; exit 2 ;;
    :) echo "buildve.sh: -$OPTARG needs an argument" >&2; exit 2 ;;
  esac
done

REPO=$(git rev-parse --show-toplevel)
cd "$REPO"

VE_DIR="tools/build_virtual_environment/ve"
DOCKERFILE="$VE_DIR/Dockerfile"
[[ -f "$DOCKERFILE" ]] || { echo "buildve.sh: no $DOCKERFILE under $REPO" >&2; exit 1; }

REV=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# The tree digest: tracked modifications AND untracked content, so two builds
# from one commit with different working trees get different digests.
# LC_ALL=C sort is load-bearing for reproducibility, and hashing the NAME
# beside the content is what makes a rename visible.
tree_digest() {
  {
    git diff HEAD
    git ls-files --others --exclude-standard | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$(git hash-object "$f")" "$f"
    done
  } | git hash-object --stdin
}
TREE=$(tree_digest)
EMPTY_BLOB=$(printf '' | git hash-object --stdin)
if [[ "$TREE" == "$EMPTY_BLOB" ]]; then DIRTY="false"; else DIRTY="true"; fi

echo "Building VE image"
echo "  repo    : $REPO"
echo "  branch  : $BRANCH"
echo "  commit  : $REV"
echo "  dirty   : $DIRTY"
echo "  tree    : $TREE"
echo "  tag     : $TAG"
echo

# The base's baked TLS certs expire and are refreshed by republishing the base
# image. `docker build` reuses a local base without checking the registry, so a
# stale one means expired certs and readiness checks that time out — failures
# that read as product bugs rather than as an out-of-date image.
echo "Force-pulling atsigncompany/vebase:latest (keeps the VE TLS certs fresh)"
docker pull atsigncompany/vebase:latest \
  || echo "WARNING: could not pull atsigncompany/vebase:latest; using the local image (its TLS certs may be stale)"

echo "Generate atDirectory binary (root) [in dart:3.11.2 Linux container]"
docker run --rm -v "${REPO}:/app" -w /app/packages/at_root_server dart:3.11.2 \
  sh -c 'dart pub get && dart compile exe bin/main.dart -o root' || exit 1

echo "Generate atServer binary (secondary) [in dart:3.11.2 Linux container]"
docker run --rm -v "${REPO}:/app" -w /app/packages/at_secondary_server dart:3.11.2 \
  sh -c 'dart pub get && dart compile exe bin/main.dart -o secondary' || exit 1

echo "Copy root and secondary binaries into $VE_DIR/contents"
mkdir -p "$VE_DIR/contents/atsign/root" "$VE_DIR/contents/atsign/secondary"
cp packages/at_root_server/root "$VE_DIR/contents/atsign/root/"
cp packages/at_root_server/pubspec.yaml "$VE_DIR/contents/atsign/root/"
chmod 755 "$VE_DIR/contents/atsign/root/root"
cp packages/at_secondary_server/secondary "$VE_DIR/contents/atsign/secondary/"
cp packages/at_secondary_server/pubspec.yaml "$VE_DIR/contents/atsign/secondary/"
chmod 755 "$VE_DIR/contents/atsign/secondary/secondary"

echo "Build docker image"
( cd "$VE_DIR" && docker build \
    --progress="$PROGRESS" \
    --label "org.opencontainers.image.revision=$REV" \
    --label "org.opencontainers.image.source=at_server" \
    --label "org.opencontainers.image.description=Atsign Virtual Environment built from a working tree" \
    --label "com.atsign.ve.revision=$REV" \
    --label "com.atsign.ve.branch=$BRANCH" \
    --label "com.atsign.ve.dirty=$DIRTY" \
    --label "com.atsign.ve.tree=$TREE" \
    -f ./Dockerfile -t "$TAG" . ) || { echo "buildve.sh: docker build failed" >&2; exit 1; }

echo
echo "Verifying the image is the one this tree just built"

# The BUILD reads its own labels back, not merely the reader. The failure mode
# being guarded is "the override silently stops being applied", and a writer
# that catches it goes red where the mistake was made instead of surfacing
# hours later as an image somebody refuses to run.
BUILT_REV=$(docker image inspect --format '{{ index .Config.Labels "com.atsign.ve.revision" }}' "$TAG")
BUILT_TREE=$(docker image inspect --format '{{ index .Config.Labels "com.atsign.ve.tree" }}' "$TAG")
if [[ "$BUILT_REV" != "$REV" ]]; then
  echo "buildve.sh: $TAG reports com.atsign.ve.revision '$BUILT_REV', expected '$REV'." >&2
  echo "            docker reused an image built from another commit." >&2
  exit 1
fi
if [[ "$BUILT_TREE" != "$TREE" ]]; then
  echo "buildve.sh: $TAG reports com.atsign.ve.tree '$BUILT_TREE', expected '$TREE'." >&2
  exit 1
fi
echo "  com.atsign.ve.revision matches HEAD"
echo "  com.atsign.ve.tree matches this working tree"

# `file` is not in the image, so read the ELF magic directly: 0x7f 'E' 'L' 'F'.
# A placeholder or a truncated copy fails this.
docker run --rm --entrypoint /bin/sh "$TAG" -c '
  fail=0
  for f in /atsign/root/root /atsign/secondary/secondary; do
    if [ ! -f "$f" ]; then echo "  MISSING  $f"; fail=1; continue; fi
    magic=$(head -c 4 "$f" | od -An -tx1 | tr -d " \n")
    size=$(wc -c < "$f")
    if [ "$magic" != "7f454c46" ]; then
      echo "  NOT AN EXECUTABLE  $f (magic $magic, $size bytes)"; fail=1; continue
    fi
    echo "  ok  $f  ($size bytes)"
  done
  exit $fail
' || { echo "buildve.sh: the image does not contain the built artefacts" >&2; exit 1; }

echo
if [[ "$DIRTY" == "true" ]]; then
  echo "Built $TAG from $BRANCH @ ${REV:0:9}+${TREE:0:9} (DIRTY working tree)"
  echo
  echo "Report a result from this image as \"against ${REV:0:9}+${TREE:0:9}\","
  echo "never as \"against ${REV:0:9}\" — the commit alone does not identify it."
else
  echo "Built $TAG from $BRANCH @ ${REV:0:9} (clean working tree)"
fi

#!/usr/bin/env bash
#
# check-upstream.sh — Diff upstream vLLM ROCm Dockerfiles against our last ported snapshot.
#
# Usage:
#   ./scripts/check-upstream.sh [vllm-commit-ish]
#
#   If no commit is given, defaults to 'main' (latest).
#   On first run, saves a snapshot to upstream/ as a baseline.
#   On subsequent runs, diffs the current upstream against the saved snapshot.
#
# Examples:
#   ./scripts/check-upstream.sh                          # diff latest upstream vs our snapshot
#   ./scripts/check-upstream.sh v0.15.1                  # diff a specific tag
#   ./scripts/check-upstream.sh 6c0064571                # diff a specific commit
#   ./scripts/check-upstream.sh --save                   # save current upstream as new baseline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
UPSTREAM_DIR="$REPO_ROOT/upstream"
VLLM_REPO="https://github.com/vllm-project/vllm.git"

# Files we track from upstream
TRACKED_FILES=(
  "docker/Dockerfile.rocm_base"
  "docker/Dockerfile.rocm"
)

# --- helpers ---------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[$(date '+%H:%M:%S')] $*"; }

fetch_file() {
  local commit="$1" file="$2"
  curl -sLf "https://raw.githubusercontent.com/vllm-project/vllm/${commit}/${file}"
}

# --- argument parsing ------------------------------------------------------

SAVE_MODE=false
COMMIT="main"

for arg in "$@"; do
  case "$arg" in
    --save) SAVE_MODE=true ;;
    --help|-h)
      echo "Usage: $0 [--save] [<commit-ish>]"
      echo ""
      echo "  --save    Save the fetched upstream files as the new baseline snapshot."
      echo "  <commit>  Git ref (tag, branch, commit hash) to fetch. Default: main."
      exit 0
      ;;
    *) COMMIT="$arg" ;;
  esac
done

# --- fetch upstream files --------------------------------------------------

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

info "Fetching upstream vLLM Dockerfiles at ref '$COMMIT' ..."
for f in "${TRACKED_FILES[@]}"; do
  out="$TMPDIR/$(basename "$f")"
  if fetch_file "$COMMIT" "$f" > "$out" 2>/dev/null; then
    info "  OK  $f ($(wc -l < "$out") lines)"
  else
    rm -f "$out"
    info "  MISS $f (file may have been removed or renamed upstream)"
  fi
done

# --- save mode: write baseline snapshot ------------------------------------

if $SAVE_MODE; then
  SNAPSHOT_DIR="$UPSTREAM_DIR/${COMMIT}"
  mkdir -p "$SNAPSHOT_DIR"
  for f in "${TRACKED_FILES[@]}"; do
    src="$TMPDIR/$(basename "$f")"
    if [ -f "$src" ]; then
      cp "$src" "$SNAPSHOT_DIR/$(basename "$f")"
    fi
  done
  info "Saved upstream snapshot to $SNAPSHOT_DIR/"
  exit 0
fi

# --- diff mode: compare against saved snapshot -----------------------------

# Find the most recent snapshot
SNAPSHOT_DIR=$(ls -1dt "$UPSTREAM_DIR"/*/ 2>/dev/null | head -1 || true)

if [ -z "$SNAPSHOT_DIR" ]; then
  info "No previous snapshot found. Saving current upstream as baseline."
  SNAPSHOT_DIR="$UPSTREAM_DIR/${COMMIT}"
  mkdir -p "$SNAPSHOT_DIR"
  for f in "${TRACKED_FILES[@]}"; do
    src="$TMPDIR/$(basename "$f")"
    if [ -f "$src" ]; then
      cp "$src" "$SNAPSHOT_DIR/$(basename "$f")"
    fi
  done
  info "Baseline saved to $SNAPSHOT_DIR/"
  info "Run again later to diff against this snapshot."
  exit 0
fi

info "Diffing upstream ($COMMIT) against snapshot ($(basename "$SNAPSHOT_DIR")) ..."
echo ""
echo "================================================================================"
echo ""

CHANGES_FOUND=false

for f in "${TRACKED_FILES[@]}"; do
  NEW="$TMPDIR/$(basename "$f")"
  OLD="$SNAPSHOT_DIR/$(basename "$f")"

  if [ ! -f "$NEW" ] && [ ! -f "$OLD" ]; then
    continue
  fi

  if [ ! -f "$NEW" ]; then
    echo "--- $f  (REMOVED upstream)"
    CHANGES_FOUND=true
    echo ""
    continue
  fi

  if [ ! -f "$OLD" ]; then
    echo "--- $f  (NEW file, not in snapshot)"
    CHANGES_FOUND=true
    wc -l < "$NEW" | xargs echo "    $f: lines"
    echo ""
    continue
  fi

  if diff -q "$OLD" "$NEW" >/dev/null 2>&1; then
    echo "--- $f  (unchanged)"
  else
    echo "--- $f  (CHANGED)  +$(diff "$OLD" "$NEW" | grep '^>' | wc -l)/-$(diff "$OLD" "$NEW" | grep '^<' | wc -l) lines"
    CHANGES_FOUND=true

    # Highlight key changes: ARG, ENV, FROM, RUN apt-get, pip install, git clone
    echo ""
    echo "    Key changes:"
    diff "$OLD" "$NEW" | grep -E '^[<>].*(ARG |ENV |FROM |apt-get install|pip install|git clone|git checkout|GPU_ARCH|PYTORCH_ROCM|ROCM_PATH|ROCm)' | sed 's/^</[-] /;s/^>/[+] /' || true
    echo ""

    # Offer to show full diff
    echo "    Full diff available with: diff $(basename "$SNAPSHOT_DIR")/$(basename "$f") <(curl ...)"
  fi
  echo ""
done

# --- summary ---------------------------------------------------------------

echo "================================================================================"
if $CHANGES_FOUND; then
  echo "CHANGES DETECTED — review the diffs above and update your generic Dockerfile."
  echo ""
  echo "Next steps:"
  echo "  1. Review the changes above"
  echo "  2. ./scripts/scaffold-version.sh <new-version-name>"
  echo "  3. Manually apply relevant upstream changes to the new generic Dockerfile"
  echo "  4. Build and test on ml-lab"
  echo "  5. When done: ./scripts/check-upstream.sh --save  (update baseline)"
else
  echo "No changes detected between upstream and our last snapshot."
fi

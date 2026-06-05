#!/usr/bin/env bash
#
# scaffold-version.sh — Bootstrap a new version directory from the latest existing one.
#
# Usage:
#   ./scripts/scaffold-version.sh <new-version-name> [--from <existing-version>]
#
# Examples:
#   ./scripts/scaffold-version.sh vllm0.15-rocm7.0.0
#   ./scripts/scaffold-version.sh vllm0.15-rocm7.0.0 --from vllm0.14-rocm7.0.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GENERIC_DIR="$REPO_ROOT/generic"

# --- helpers ---------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "WARNING: $*" >&2; }

# --- argument parsing ------------------------------------------------------

NEW_VERSION=""
FROM_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      FROM_VERSION="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 <new-version-name> [--from <existing-version>]"
      echo ""
      echo "  Creates a new directory generic/<new-version-name>/ by copying an"
      echo "  existing version's Dockerfile.  If --from is not given, the latest"
      echo "  version (by directory name sort) is used."
      echo ""
      echo "  After copying, you MUST manually update version strings in the new"
      echo "  Dockerfile (ROCm version, PyTorch version, vLLM commit, etc.)."
      echo ""
      echo "Examples:"
      echo "  $0 vllm0.15-rocm7.0.0"
      echo "  $0 vllm0.15-rocm7.1.0 --from vllm0.14-rocm7.0.0"
      exit 0
      ;;
    *) NEW_VERSION="$1"; shift ;;
  esac
done

# --- validate --------------------------------------------------------------

[ -z "$NEW_VERSION" ] && die "New version name is required."
[ -d "$GENERIC_DIR" ] || die "generic/ directory not found at $GENERIC_DIR"

# --- pick source version ---------------------------------------------------

if [ -n "$FROM_VERSION" ]; then
  SRC_DIR="$GENERIC_DIR/$FROM_VERSION"
  [ -d "$SRC_DIR" ] || die "Source version '$FROM_VERSION' not found at $SRC_DIR"
else
  # Use the latest version directory by name (ls sort)
  SRC_DIR=$(ls -1dt "$GENERIC_DIR"/*/ 2>/dev/null | head -1 || true)
  [ -z "$SRC_DIR" ] && die "No existing version directories found in $GENERIC_DIR/"
  FROM_VERSION=$(basename "$SRC_DIR")
fi

DST_DIR="$GENERIC_DIR/$NEW_VERSION"

# --- guard against overwrite -----------------------------------------------

if [ -d "$DST_DIR" ]; then
  die "Destination directory '$DST_DIR' already exists. Remove it first or pick a different name."
fi

# --- scaffold --------------------------------------------------------------

info "Scaffolding $NEW_VERSION from $FROM_VERSION ..."

mkdir -p "$DST_DIR"
cp "$SRC_DIR/Dockerfile" "$DST_DIR/Dockerfile"

# Copy the version manifest too — in the new flow this is the file you edit
# (sync-versions.sh / generate-wmf-template.sh both require it to exist).
if [ -f "$SRC_DIR/versions.env" ]; then
  cp "$SRC_DIR/versions.env" "$DST_DIR/versions.env"
  info "Created $DST_DIR/Dockerfile and $DST_DIR/versions.env"
else
  warn "No versions.env in $SRC_DIR — copied Dockerfile only."
  warn "Create $DST_DIR/versions.env before running sync-versions.sh."
  info "Created $DST_DIR/Dockerfile"
fi

info ""
info "Next steps:"
info "  1. Sync version pins from upstream:"
info "       ./scripts/sync-versions.sh $NEW_VERSION <upstream-ref>"
info "     Review versions.env.new (set BASE_IMAGE/ROCM_VERSION/TORCH_SPEC per"
info "     the printed hints; confirm GPU archs), then:"
info "       mv generic/$NEW_VERSION/versions.env.new generic/$NEW_VERSION/versions.env"
info "  2. Triage structural upstream changes:"
info "       ./scripts/plan-upgrade.sh $NEW_VERSION <upstream-ref> <baseline-ref>"
info "     Only edit the Dockerfile for [ENV] additions and [CONFLICT] items."
info "  3. Build and test the image:"
info "       docker build --network=host -t vllm-rocm-debian:$NEW_VERSION ./generic/$NEW_VERSION"
info "  4. Run the smoke test (see docs/upgrade-runbook.md)"
info "  5. When verified, commit:"
info "       git add generic/$NEW_VERSION && git commit -m 'add $NEW_VERSION generic Dockerfile + versions.env'"

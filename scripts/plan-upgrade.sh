#!/usr/bin/env bash
#
# plan-upgrade.sh — Turn the upstream diff into a categorized, actionable worklist.
#
# check-upstream.sh tells you THAT upstream changed. sync-versions.sh handles
# the version-pin bumps. This script handles everything else — the structural
# churn (new stages, new ENV, new deps) — by triaging each change into:
#
#   [AUTO]    Version-pin bump already handled by sync-versions.sh. Confirm only.
#   [ENV]     New/changed ENV var. Usually safe to copy into our runtime ENV.
#   [STAGE]   New upstream build stage. We only build: builder, mori, fa, aiter,
#             vllm. If the new stage isn't one of those, it's almost certainly
#             SKIP (a feature we don't ship). Flagged so the skip is a decision.
#   [DEP]     New apt/pip dependency inside a stage we DO build. Review.
#   [CONFLICT] Touches one of our WMF deltas (apt/repo, base image, chunker,
#             arch, perf ENV). Do NOT copy blindly — reconcile by hand.
#
# Usage:
#   ./scripts/plan-upgrade.sh <generic-version> <upstream-ref> [<baseline-ref>]
#
# If <baseline-ref> is omitted, uses the most recent saved snapshot in upstream/.
#
# Example:
#   ./scripts/plan-upgrade.sh vllm0.14-rocm7.0.0 v0.22.0 v0.14.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GENERIC_DIR="$REPO_ROOT/generic"
UPSTREAM_DIR="$REPO_ROOT/upstream"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[$(date '+%H:%M:%S')] $*"; }

[ $# -ge 2 ] || die "Usage: $0 <generic-version> <upstream-ref> [<baseline-ref>]"
VERSION="$1"; REF="$2"; BASELINE="${3:-}"

DF="$GENERIC_DIR/$VERSION/Dockerfile"
[ -f "$DF" ] || die "generic Dockerfile not found at $DF"

# Stages we actually build (anything else upstream adds is presumed SKIP).
OUR_STAGES_RE='^(builder|torch-libs-chunker|mori-builder|flashattention-builder|aiter-builder|vllm-builder)$'

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
fetch() { curl -sLf "https://raw.githubusercontent.com/vllm-project/vllm/${1}/docker/${2}"; }

# --- resolve baseline ------------------------------------------------------
if [ -z "$BASELINE" ]; then
  snap=$(ls -1dt "$UPSTREAM_DIR"/*/ 2>/dev/null | head -1 || true)
  [ -z "$snap" ] && die "No baseline ref given and no snapshot in upstream/. Run check-upstream.sh first."
  BASELINE="$(basename "$snap")"
  OLD_BASE="$UPSTREAM_DIR/$BASELINE/Dockerfile.rocm_base"
  OLD_ROCM="$UPSTREAM_DIR/$BASELINE/Dockerfile.rocm"
else
  fetch "$BASELINE" Dockerfile.rocm_base > "$TMPDIR/old_base" 2>/dev/null || true
  fetch "$BASELINE" Dockerfile.rocm      > "$TMPDIR/old_rocm" 2>/dev/null || true
  OLD_BASE="$TMPDIR/old_base"; OLD_ROCM="$TMPDIR/old_rocm"
fi

info "Fetching upstream @ $REF ..."
fetch "$REF" Dockerfile.rocm_base > "$TMPDIR/new_base" 2>/dev/null || die "fetch failed"
fetch "$REF" Dockerfile.rocm      > "$TMPDIR/new_rocm" 2>/dev/null || true

# --- classify added lines (lines present in NEW, absent in OLD) ------------
declare -a A_AUTO A_ENV A_STAGE A_DEP A_CONFLICT

# version-pin ARGs handled by sync-versions.sh
AUTO_RE='^\+ARG[[:space:]]+(TRITON_BRANCH|PYTORCH_BRANCH|FA_BRANCH|AITER_BRANCH|MORI_BRANCH|BASE_IMAGE)='
# our WMF deltas — anything touching these needs hand reconciliation
CONFLICT_RE='(repo\.radeon\.com|apt\.wikimedia|/etc/apt/|hipblaslt|rocblas|torch_lib_chunks|PYTORCH_ROCM_ARCH|GPU_ARCHS|GPU_TARGETS|--chown|USER somebody|\.a$|rm -f /opt)'

classify() {
  local oldf="$1" newf="$2" label="$3"
  [ -f "$newf" ] || return 0
  # unified diff; consider only added (+) content lines
  while IFS= read -r line; do
    case "$line" in
      +++*|+) continue ;;
      \+*) : ;;     # an added line
      *) continue ;;
    esac
    local body="${line:1}"
    [ -z "${body// }" ] && continue

    if [[ "$line" =~ $AUTO_RE ]]; then
      A_AUTO+=("$label: ${body}")
    elif [[ "$body" =~ $CONFLICT_RE ]]; then
      A_CONFLICT+=("$label: ${body}")
    elif [[ "$body" =~ ^FROM[[:space:]] ]]; then
      # new/changed stage definition
      local st; st=$(echo "$body" | sed -nE 's/.*[[:space:]][Aa][Ss][[:space:]]+([A-Za-z0-9_-]+).*/\1/p')
      if [ -n "$st" ] && ! [[ "$st" =~ $OUR_STAGES_RE ]]; then
        A_STAGE+=("$label: stage '$st'  ->  likely SKIP (we don't build it)  [${body}]")
      else
        A_STAGE+=("$label: ${body}")
      fi
    elif [[ "$body" =~ ^ENV[[:space:]]|^[[:space:]]*ENV[[:space:]] ]]; then
      A_ENV+=("$label: ${body}")
    elif [[ "$body" =~ apt-get[[:space:]]+install|pip[[:space:]]+install|uv[[:space:]]+pip ]]; then
      A_DEP+=("$label: ${body}")
    fi
  done < <(diff -u "$oldf" "$newf" 2>/dev/null || true)
}

classify "$OLD_BASE" "$TMPDIR/new_base" "rocm_base"
classify "$OLD_ROCM" "$TMPDIR/new_rocm" "rocm"

# --- report ----------------------------------------------------------------
section() {
  local title="$1"; shift
  local -n arr="$1"
  echo ""
  echo "── $title ── (${#arr[@]})"
  if [ "${#arr[@]}" -eq 0 ]; then echo "   (none)"; return; fi
  local x; for x in "${arr[@]}"; do echo "   $x"; done
}

echo ""
echo "================================================================================"
echo " UPGRADE PLAN: $VERSION   (baseline $BASELINE  ->  upstream $REF)"
echo "================================================================================"

echo ""
echo "STEP 1 — run sync-versions.sh first (handles the [AUTO] items below):"
echo "   ./scripts/sync-versions.sh $VERSION $REF"

section "[AUTO]  version-pin bumps — handled by sync-versions.sh, just confirm" A_AUTO
section "[ENV]   new ENV vars — usually safe to add to our runtime ENV block"    A_ENV
section "[STAGE] new upstream build stages — most are SKIP (not in our 6 stages)" A_STAGE
section "[DEP]   new deps inside build steps — review if they hit a stage we build" A_DEP
section "[CONFLICT] touches a WMF delta — DO NOT copy blindly, reconcile by hand"  A_CONFLICT

echo ""
echo "================================================================================"
echo "Suggested workflow:"
echo "  1. sync-versions.sh  (resolves [AUTO])  → review versions.env.new"
echo "  2. Copy [ENV] additions into the runtime ENV block if relevant"
echo "  3. For each [STAGE]: confirm SKIP, or add a builder stage if we need it"
echo "  4. Hand-reconcile every [CONFLICT] against our Debian/WMF deltas"
echo "  5. Build + smoke test (docs/upgrade-runbook.md)"
echo "  6. check-upstream.sh --save  (update baseline for next time)"
echo "================================================================================"

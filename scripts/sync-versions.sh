#!/usr/bin/env bash
#
# sync-versions.sh — Update a generic image's versions.env from upstream pins.
#
# Reads the component version ARGs that upstream vLLM declares in
# docker/Dockerfile.rocm_base (and docker/Dockerfile.rocm) at a given ref,
# maps them onto the keys in generic/<version>/versions.env, and writes a
# PROPOSED versions.env.new for review.
#
# What it DOES sync (these track upstream):
#   TRITON / PYTORCH (-> TORCH_SPEC hint), FA_BRANCH, AITER_BRANCH, MORI_BRANCH,
#   VLLM_REF, BASE_IMAGE (-> ROCM_VERSION hint).
#
# What it DELIBERATELY does NOT overwrite (these are WMF/hardware-owned):
#   PYTORCH_ROCM_ARCH, *_GPU_ARCHS, *_GPU_TARGETS — your target AMD GPUs.
#   These are preserved as-is, and a reminder is printed so a human confirms
#   them against current hardware (MI210=gfx90a, MI300X=gfx942, MI350=gfx950).
#
# Usage:
#   ./scripts/sync-versions.sh <generic-version> <upstream-ref>
#
# Examples:
#   ./scripts/sync-versions.sh vllm0.14-rocm7.0.0 v0.22.0
#   ./scripts/sync-versions.sh vllm0.22-rocm7.2.2 v0.22.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GENERIC_DIR="$REPO_ROOT/generic"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- args ------------------------------------------------------------------
[ $# -ge 2 ] || die "Usage: $0 <generic-version> <upstream-ref>"
VERSION="$1"
REF="$2"

ENV_FILE="$GENERIC_DIR/$VERSION/versions.env"
[ -f "$ENV_FILE" ] || die "versions.env not found at $ENV_FILE"

# --- fetch upstream Dockerfiles at the ref ---------------------------------
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
fetch() { curl -sLf "https://raw.githubusercontent.com/vllm-project/vllm/${REF}/$1"; }

info "Fetching upstream pins at ref '$REF' ..."
fetch "docker/Dockerfile.rocm_base" > "$TMPDIR/base" 2>/dev/null || die "could not fetch Dockerfile.rocm_base@$REF"
fetch "docker/Dockerfile.rocm"      > "$TMPDIR/rocm" 2>/dev/null || true

# --- parse an upstream ARG value (strips quotes + trailing comment) --------
up_arg() {
  # up_arg <name> <file...>  -> prints value or empty
  local name="$1"; shift
  local raw
  raw=$(grep -hE "^ARG[[:space:]]+${name}=" "$@" 2>/dev/null | head -1 || true)
  [ -z "$raw" ] && return 0
  raw="${raw#*=}"                       # drop 'ARG NAME='
  raw="${raw%%#*}"                      # drop trailing comment
  raw="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  raw="${raw%\"}"; raw="${raw#\"}"      # strip surrounding quotes
  printf '%s' "$raw"
}

U_TRITON=$(up_arg TRITON_BRANCH  "$TMPDIR/base")
U_PYTORCH=$(up_arg PYTORCH_BRANCH "$TMPDIR/base")
U_FA=$(up_arg FA_BRANCH           "$TMPDIR/base" "$TMPDIR/rocm")
U_AITER=$(up_arg AITER_BRANCH     "$TMPDIR/base" "$TMPDIR/rocm")
U_MORI=$(up_arg MORI_BRANCH       "$TMPDIR/base" "$TMPDIR/rocm")
U_BASE=$(up_arg BASE_IMAGE        "$TMPDIR/base")

# --- read current env (KEY=value, ignore comments) -------------------------
declare -A CUR
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | sed -e 's/[[:space:]]*$//')"
  [[ "$line" == *=* ]] || continue
  k="${line%%=*}"; v="${line#*=}"
  k="$(echo "$k" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  CUR["$k"]="$v"
done < "$ENV_FILE"

# --- map upstream -> our keys; build the proposed value set ----------------
# Component refs sync directly when upstream provided a value.
declare -A NEW
for k in "${!CUR[@]}"; do NEW["$k"]="${CUR[$k]}"; done

sync_key() { # sync_key <our_key> <upstream_value>
  local key="$1" val="$2"
  [ -z "$val" ] && return 0
  [[ -v CUR["$key"] ]] || return 0      # only touch keys we already track
  NEW["$key"]="$val"
}

sync_key FA_BRANCH    "$U_FA"
sync_key AITER_BRANCH "$U_AITER"
sync_key MORI_BRANCH  "$U_MORI"

# Keys that need human-readable hints rather than blind copy:
HINTS=()
[ -n "$U_BASE" ]    && HINTS+=("BASE_IMAGE: upstream uses '$U_BASE' (Ubuntu). Set your Debian BASE_IMAGE + ROCM_VERSION/ROCM_PATH_VERSION to the matching ROCm.")
[ -n "$U_PYTORCH" ] && HINTS+=("PYTORCH: upstream builds torch from branch '$U_PYTORCH'. Pick the matching torch wheel for TORCH_SPEC/TORCH_INDEX_URL.")
[ -n "$U_TRITON" ]  && HINTS+=("TRITON: upstream pins triton '$U_TRITON' (we inherit triton via the torch wheel; usually no action).")

# --- detect GPU-arch keys we are intentionally preserving ------------------
ARCH_KEYS=()
for k in "${!CUR[@]}"; do
  case "$k" in
    PYTORCH_ROCM_ARCH|*_GPU_ARCHS|*_GPU_TARGETS) ARCH_KEYS+=("$k") ;;
  esac
done

# --- write proposed versions.env.new (preserve file order + comments) ------
OUT="$GENERIC_DIR/$VERSION/versions.env.new"
{
  echo "# versions.env — PROPOSED update synced from upstream vLLM @ $REF"
  echo "# Generated $(date '+%Y-%m-%d %H:%M:%S'). Review, then: mv versions.env.new versions.env"
  echo "#"
  echo "# GPU-arch values were PRESERVED, not synced. Confirm they match current"
  echo "# WMF hardware: MI210=gfx90a, MI300X=gfx942, MI350=gfx950 (coming soon)."
  echo "#"
  echo ""
  # Re-emit original lines, swapping in synced values for matched keys.
  # Skip the original leading comment/banner block to avoid duplicate headers.
  past_header=0
  while IFS= read -r line; do
    if [ "$past_header" -eq 0 ]; then
      # header ends at the first non-comment, non-blank line
      if [[ -n "${line// }" ]] && [[ "${line#\#}" == "$line" ]]; then
        past_header=1
      else
        continue
      fi
    fi
    stripped="${line%%#*}"; key=""
    if [[ "$stripped" == *=* ]]; then
      key="$(echo "${stripped%%=*}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    fi
    if [ -n "$key" ] && [[ -v NEW["$key"] ]] && [ "${NEW[$key]}" != "${CUR[$key]}" ]; then
      echo "${key}=${NEW[$key]}    # synced from upstream@$REF (was ${CUR[$key]})"
    elif [ -n "$key" ]; then
      # preserve arch keys with an inline reminder
      case "$key" in
        PYTORCH_ROCM_ARCH|*_GPU_ARCHS|*_GPU_TARGETS)
          echo "${line}    # REVIEW: confirm GPU archs vs current hardware" ;;
        *) echo "$line" ;;
      esac
    else
      echo "$line"
    fi
  done < "$ENV_FILE"
} > "$OUT"

# --- report ----------------------------------------------------------------
echo ""
echo "================================================================================"
info "Proposed update written to: $OUT"
echo ""
echo "SYNCED component pins (review against upstream release notes):"
for k in FA_BRANCH AITER_BRANCH MORI_BRANCH; do
  if [[ -v CUR["$k"] ]] && [ "${NEW[$k]}" != "${CUR[$k]}" ]; then
    echo "  [~] $k: ${CUR[$k]} -> ${NEW[$k]}"
  fi
done

echo ""
echo "MANUAL hints (upstream changed things that need a human decision):"
for h in "${HINTS[@]}"; do echo "  [!] $h"; done

echo ""
echo "PRESERVED GPU-arch keys (NOT auto-synced — confirm vs MI210/MI300X/MI350):"
for k in "${ARCH_KEYS[@]}"; do echo "  [=] $k=${CUR[$k]}"; done

echo ""
echo "Next:"
echo "  1. Review $OUT"
echo "  2. Adjust GPU-arch keys if hardware changed (e.g. add gfx950 for MI350)"
echo "  3. mv $OUT $ENV_FILE"
echo "  4. ./scripts/plan-upgrade.sh $VERSION $REF   # for the structural diff"
echo "================================================================================"

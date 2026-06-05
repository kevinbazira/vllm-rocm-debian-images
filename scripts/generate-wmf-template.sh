#!/usr/bin/env bash
#
# generate-wmf-template.sh — Convert a generic Dockerfile to a WMF
# production Dockerfile.template, driven by versions.env.
#
# This is a thin wrapper around scripts/generic_to_wmf.py. It:
#   1. expands version ARGs from generic/<version>/versions.env
#   2. applies the fixed WMF deltas (base image, apt mirror, proxy, chown,
#      USER somebody, render-group, build-dep trimming, header)
#   3. writes wmf/<short>/Dockerfile.template
#   4. self-checks the result against any existing committed template
#      (instruction-set equality) and warns on ordering drift.
#
# Usage:
#   ./scripts/generate-wmf-template.sh <generic-version> \
#       [--base-tag <amd-pytorch-common-tag>] [--rocm-suffix <NN>] \
#       [--output <dir>] [--check <existing-template>]
#
# Example:
#   ./scripts/generate-wmf-template.sh vllm0.14-rocm7.0.0 \
#       --base-tag 0.0.1-2-20260118 --rocm-suffix 70 \
#       --check wmf/vllm014/Dockerfile.template

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GENERIC_DIR="$REPO_ROOT/generic"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "[$(date '+%H:%M:%S')] $*"; }

VERSION=""; OUTPUT_DIR=""; BASE_TAG="0.0.1-2-20260118"; ROCM_SUFFIX=""; CHECK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-tag)    BASE_TAG="$2"; shift 2 ;;
    --rocm-suffix) ROCM_SUFFIX="$2"; shift 2 ;;
    --output)      OUTPUT_DIR="$2"; shift 2 ;;
    --check)       CHECK="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) VERSION="$1"; shift ;;
  esac
done

[ -z "$VERSION" ] && die "generic version name required"
SRC="$GENERIC_DIR/$VERSION/Dockerfile"
ENVF="$GENERIC_DIR/$VERSION/versions.env"
[ -f "$SRC" ]  || die "Dockerfile not found at $SRC"
[ -f "$ENVF" ] || die "versions.env not found at $ENVF"

# derive ROCm apt suffix (e.g. 7.0 -> 70) if not given
if [ -z "$ROCM_SUFFIX" ]; then
  rv="$(grep -E '^ROCM_VERSION=' "$ENVF" | head -1 | cut -d= -f2 | tr -d ' ')"
  ROCM_SUFFIX="$(echo "$rv" | tr -d '.' | cut -c1-2)"
fi

if [ -z "$OUTPUT_DIR" ]; then
  SHORT="$(echo "$VERSION" | sed -E 's/vllm0\.([0-9]+)-rocm.*/vllm0\1/')"
  OUTPUT_DIR="$REPO_ROOT/wmf/$SHORT"
fi
mkdir -p "$OUTPUT_DIR"
DST="$OUTPUT_DIR/Dockerfile.template"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- 1. expand version ARGs (NOT structural path ARGs) ---------------------
python3 - "$SRC" "$ENVF" > "$TMP/expanded" <<'PYEOF'
import sys, re
df, env = sys.argv[1], sys.argv[2]
args = {}
for ln in open(env):
    ln = ln.split('#')[0].strip()
    if '=' in ln:
        k, v = ln.split('=', 1); args[k.strip()] = v.strip()
for k in ('TORCH_LIB_PATH','APT_PREF','HIPBLASLT_FULL_PATH','ROCBLAS_FULL_PATH'):
    args.pop(k, None)
def expand(s):
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r'\$\{([A-Z_][A-Z0-9_]*)\}',
                   lambda m: args.get(m.group(1), m.group(0)), s)
    return s
for ln in open(df):
    sys.stdout.write(expand(ln.rstrip('\n')) + '\n')
PYEOF

# --- 2. transform ----------------------------------------------------------
info "Generating WMF template: $VERSION (base=$BASE_TAG, rocm-suffix=$ROCM_SUFFIX)"
python3 "$SCRIPT_DIR/generic_to_wmf.py" "$TMP/expanded" "$BASE_TAG" "$ROCM_SUFFIX" > "$DST"
info "Wrote $DST"

# --- 3. self-check against an existing committed template ------------------
if [ -n "$CHECK" ] && [ -f "$CHECK" ]; then
  python3 - "$DST" "$CHECK" <<'PYEOF'
import sys
def fn(p):
    return [l.rstrip() for l in open(p) if not l.lstrip().startswith('#') and l.strip()]
gen, ref = fn(sys.argv[1]), fn(sys.argv[2])
gs, rs = set(gen), set(ref)
missing, extra = rs - gs, gs - rs
if missing or extra:
    print("SELF-CHECK FAILED — instruction set differs from", sys.argv[2])
    for m in sorted(missing): print("  MISSING:", m[:100])
    for e in sorted(extra):   print("  EXTRA:  ", e[:100])
    sys.exit(1)
if gen != ref:
    print("SELF-CHECK: instruction SETS match; ordering differs (functionally equivalent).")
    sys.exit(0)
print("SELF-CHECK PASSED — byte-identical to", sys.argv[2])
PYEOF
fi

cat <<EOF

### WMF-REVIEW — confirm before committing to operations/docker-images-production-images:
  1. BASE IMAGE tag '$BASE_TAG' is current.
  2. ROCm mirror suffix 'amd-rocm$ROCM_SUFFIX' matches packages added to the WMF apt mirror.
     If ROCm changed, file the puppet/aptrepo change FIRST (see T415627#11557499).
  3. GPU archs in versions.env match current hardware (MI210/MI300X/MI350).
  4. Build + smoke test on ml-lab before Gerrit (docs/upgrade-runbook.md).
EOF

#!/usr/bin/env bash
#
# generate-wmf-template.sh — Convert a generic Dockerfile to WMF production template.
#
# Usage:
#   ./scripts/generate-wmf-template.sh <generic-version> [--output <dir>]
#
# The script applies the mechanical transformations needed to turn a generic
# Debian Bookworm Dockerfile into a WMF-specific Dockerfile.template:
#
#   1. Base image       → docker-registry.wikimedia.org/...
#   2. APT sources      → apt.wikimedia.org internal mirror
#   3. Proxy env vars   → ARG http_proxy + 4 ENV vars
#   4. COPY ownership   → --chown=somebody on all COPY lines
#   5. Non-root user    → USER somebody before pip install
#   6. Registry limits  → update header comment (4GB → 12GB)
#
# The output is a starting point; you MUST still review and test it.
# Sections needing manual attention are marked with "### WMF-REVIEW".
#
# Examples:
#   ./scripts/generate-wmf-template.sh vllm0.14-rocm7.0.0
#   ./scripts/generate-wmf-template.sh vllm0.14-rocm7.0.0 --output wmf/vllm014/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GENERIC_DIR="$REPO_ROOT/generic"

# --- helpers ---------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# --- argument parsing ------------------------------------------------------

VERSION=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 <generic-version> [--output <dir>]"
      echo ""
      echo "  Converts generic/<version>/Dockerfile into a WMF Dockerfile.template."
      echo "  If --output is not given, writes to wmf/<short-name>/"
      echo ""
      echo "Examples:"
      echo "  $0 vllm0.14-rocm7.0.0"
      echo "  $0 vllm0.15-rocm7.1.0 --output /tmp/wmf-test/"
      exit 0
      ;;
    *) VERSION="$1"; shift ;;
  esac
done

# --- validate --------------------------------------------------------------

[ -z "$VERSION" ] && die "Version name is required."
SRC="$GENERIC_DIR/$VERSION/Dockerfile"
[ -f "$SRC" ] || die "Generic Dockerfile not found at $SRC"

if [ -z "$OUTPUT_DIR" ]; then
  # Derive short name: vllm0.14-rocm7.0.0 → vllm014
  SHORT_NAME=$(echo "$VERSION" | sed -E 's/vllm0\.([0-9]+)-rocm([0-9]+)\..*/vllm0\1/')
  OUTPUT_DIR="$REPO_ROOT/wmf/$SHORT_NAME"
fi

# --- extract versions from the Dockerfile ----------------------------------

# Try to parse version strings from the generic Dockerfile
ROCM_VERSION=$(grep -oP 'ARG ROCM_VERSION=\K[0-9.]+' "$SRC" 2>/dev/null || echo "UNKNOWN")
VLLM_COMMIT=$(grep -oP 'git checkout \K[0-9a-f]+' "$SRC" | head -1 2>/dev/null || echo "UNKNOWN")
TORCH_VERSION=$(grep -oP 'torch==\K[0-9.]+[+][^\s"]+' "$SRC" 2>/dev/null || echo "UNKNOWN")

info "Generating WMF template from generic/$VERSION/Dockerfile"
info "  Detected ROCm version: $ROCM_VERSION"
info "  Detected vLLM commit:  $VLLM_COMMIT"
info "  Detected PyTorch:      $TORCH_VERSION"

mkdir -p "$OUTPUT_DIR"
DST="$OUTPUT_DIR/Dockerfile.template"

# --- transformation pipeline -----------------------------------------------

info "Applying transformations ..."

# Read the generic Dockerfile and apply transformations via sed/awk pipeline.
#
# We operate on the whole file, applying these changes in order:
#
# T1: Replace the header block (first comment) with WMF-specific header
# T2: Replace FROM debian:bookworm-* with FROM docker-registry.wikimedia.org/...
# T3: Add proxy env vars after each FROM line when it's a builder/runtime stage
# T4: Replace AMD repo setup with WMF mirror
# T5: Add --chown=somebody to COPY lines
# T6: Add USER somebody before pip install
# T7: Comment about apt-get clean being automatic

# We'll use Python for this since it's much more robust than sed for multi-line changes.
python3 - "$SRC" "$DST" "$ROCM_VERSION" "$VERSION" <<'PYEOF'
import sys, re

src_path = sys.argv[1]
dst_path = sys.argv[2]
rocm_version = sys.argv[3]
version_name = sys.argv[4]

with open(src_path) as f:
    content = f.read()

lines = content.split('\n')
output = []
i = 0

# --- T1: Replace header comment block ---
# Skip the initial '#' block from the generic file; we'll emit the WMF one.
while i < len(lines) and (lines[i].startswith('#') or lines[i].strip() == ''):
    i += 1

output.append('#' * 72)
output.append('# wmf-debian-vllm: ROCm, PyTorch, MoRi, FlashAttention, aiter, vLLM    #')
output.append('#                                                                      #')
output.append('# Note: Multiple RUN commands are intentionally kept separate to avoid #')
output.append('# hitting the 12GB (compressed) Docker layer limit required by the     #')
output.append('# Wikimedia Docker registry.                                           #')
output.append('#' * 72)
output.append('')

# --- Consume remaining lines ---
remaining = lines[i:]
in_runtime = False
seen_first_from = False
seen_builder_workdir = False

for line in remaining:
    # T2: Replace FROM lines
    if re.match(r'^FROM\s+debian:bookworm', line.strip()):
        # Determine stage name
        stage_match = re.search(r'\bAS\s+(\S+)', line)
        stage = stage_match.group(1) if stage_match else 'builder'
        output.append(f'FROM docker-registry.wikimedia.org/amd-pytorch-common:0.0.1-2-20260118 as {stage}')
        output.append('')
        # T3: Add proxy env vars after FROM
        if not seen_first_from:
            output.append('# Set proxy env vars required on ml-lab1002')
            seen_first_from = True
        output.append('ARG http_proxy')
        output.append('ENV http_proxy=${http_proxy}')
        output.append('ENV https_proxy=${http_proxy}')
        output.append('ENV HTTP_PROXY=${http_proxy}')
        output.append('ENV HTTPS_PROXY=${http_proxy}')
        output.append('')
        continue

    # T2b: Replace FROM builder AS / FROM base AS patterns
    if re.match(r'^FROM\s+builder\s+AS\s+', line.strip()):
        output.append(line)
        continue

    # T2c: Replace FROM ${BASE_IMAGE} patterns in later stages
    if re.match(r'^FROM\s+\$\{BASE_IMAGE\}', line.strip()):
        stage_match = re.search(r'\bAS\s+(\S+)', line)
        stage = stage_match.group(1) if stage_match else 'runtime'
        if stage == 'runtime':
            in_runtime = True
        output.append(f'FROM docker-registry.wikimedia.org/amd-pytorch-common:0.0.1-2-20260118 as {stage}')
        output.append('')
        output.append('# Set proxy env vars required on ml-lab1002')
        output.append('ARG http_proxy')
        output.append('ENV http_proxy=${http_proxy}')
        output.append('ENV https_proxy=${http_proxy}')
        output.append('ENV HTTP_PROXY=${http_proxy}')
        output.append('ENV HTTPS_PROXY=${http_proxy}')
        output.append('')
        continue

    # T4: Replace AMD repo setup block with WMF mirror
    #     (multi-line: mkdir keyrings ... wget ... echo deb ... apt-get update ... apt-get install)
    if 'mkdir -p /etc/apt/keyrings' in line:
        output.append(f'# Add Wikimedia ROCm mirror then install ROCm libs and Python tooling')
        output.append(f'RUN echo "deb http://apt.wikimedia.org/wikimedia bookworm-wikimedia thirdparty/amd-rocm{rocm_version.replace(".", "")[:2]}" > /etc/apt/sources.list.d/rocm.list \\')
        output.append(f'    && apt-get update -q')
        # Skip the original multi-line REPO setup; we'll catch continuation lines below
        continue

    # Skip continuation lines from the AMD repo setup we replaced
    if output and 'Add Wikimedia ROCm mirror' in output[-2]:
        continue
    if '&& apt-get update -q' in output[-1] and 'wget -qO' in line:
        continue
    # Skip the original "Add AMD ROCm repositories" comment
    if line.strip().startswith('# Add AMD ROCm repositories'):
        continue

    # T5: Add --chown=somebody to COPY lines (only in runtime or copy stages)
    if re.match(r'^COPY\s+--from=', line) and '--chown=' not in line:
        line = re.sub(r'(COPY\s+)', r'\1--chown=somebody ', line)

    # T6: Add USER somebody before the first pip install in runtime
    if in_runtime and re.search(r'pip install.*wheels', line):
        output.append('')
        output.append('# Switch to user "somebody" to avoid running the container as root')
        output.append('USER somebody')
        output.append('')

    # T7: Replace apt-get clean comments
    if 'Cleanup apt cache' in line or ('apt-get clean' in line and 'rm -rf /var/lib/apt/lists' in line):
        output.append(line)
        # add note
        continue

    output.append(line)

# Write the output
with open(dst_path, 'w') as f:
    f.write('\n'.join(output) + '\n')

print(f'TEMPLATE_WRITTEN={dst_path}')
PYEOF

info ""
info "WMF template written to: $DST"
info ""
info "### WMF-REVIEW — Manual steps required before this template is usable: ###"
info ""
info "  1. BASE IMAGE: Verify the amd-pytorch-common tag is current."
info "     Current in template: docker-registry.wikimedia.org/amd-pytorch-common:0.0.1-2-20260118"
info ""
info "  2. APT MIRROR: The script auto-detected ROCm version '$ROCM_VERSION'."
info "     Verify the APT source line points to the correct WMF mirror directory."
info "     If ROCm version changed, you MUST first add packages to the mirror:"
info "       → File a puppet change against operations/puppet@production"
info "       → Update hieradata for aptrepo (see T415627#11557499)"
info ""
info "  3. CHOWN: All COPY lines now have --chown=somebody. Verify none were missed."
info "     grep 'COPY --from=' $DST | grep -v chown"
info ""
info "  4. LAYER SIZES: After building, check compressed layer sizes:"
info "     docker history <image> | head -20"
info "     Ensure largest compressed layer is under 12GB."
info ""
info "  5. BUILD & TEST on ml-lab before uploading to Gerrit."
info "     See docs/upgrade-runbook.md for the full procedure."
info ""
info "Next: copy this template to the operations/docker-images-production-images repo"
info "      and follow the Gerrit workflow in the runbook."

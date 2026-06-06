# vLLM ROCm Debian Image — Upgrade Runbook

Step-by-step procedure for porting a new upstream vLLM release to the WMF Debian Docker images.

## Overview

```
                      ┌─────────────────────┐
                      │  Upstream vLLM      │
                      │  releases new tag   │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 1. Check upstream   │  scripts/check-upstream.sh
                      │    diff & changelog │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 2. Scaffold new     │  scripts/scaffold-version.sh
                      │    generic/ dir     │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 3a. Sync versions   │  scripts/sync-versions.sh
                      │     (versions.env)  │  → auto-bumps pins, preserves archs
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 3b. Triage diff     │  scripts/plan-upgrade.sh
                      │  AUTO/ENV/STAGE/... │  → only edit DF for ENV + CONFLICT
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 4. Build & smoke    │  docker build + vLLM test
                      │    test generic img │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 5. Generate WMF     │  scripts/generate-wmf-template.sh
                      │    template (+check)│  → self-checks vs committed
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 6. APT mirror       │  only if ROCm version changed
                      │    puppet change    │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 7. Build WMF img    │  docker build on ml-lab
                      │    on ml-lab        │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 8. Validate         │  MAD benchmarks + smoke test
                      │    benchmarks       │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 9. Gerrit changes   │  docker-images + puppet
                      │    & deploy         │
                      └─────────────────────┘
```

## Prerequisites

- Access to `ml-lab1002` (or equivalent AMD GPU machine with MI210/MI300X)
- Access to WMF Gerrit (`gerrit.wikimedia.org`)
- WMF Phabricator account
- Docker installed and configured on ml-lab

---

## Step 1: Check Upstream Changes

```bash
# Diff latest upstream against our last saved snapshot
./scripts/check-upstream.sh

# Or diff a specific tag
./scripts/check-upstream.sh v0.15.1
```

**What to look for in the diff:**
- New `ARG` or `ENV` variables — must be carried over
- New `apt-get install` packages — new ROCm dependencies
- New `pip install` packages — new Python build/runtime deps
- `FROM` base image changes — Debian version bumps
- GPU architecture changes (`PYTORCH_ROCM_ARCH`, `GPU_ARCHS`)
- New build stages — upstream may have added optimizations (e.g., aiter, MoRI)

Also review the [vLLM release page](https://github.com/vllm-project/vllm/releases) for the changelog between the version we have and the latest.

---

## Step 2: Scaffold New Version Directory

```bash
./scripts/scaffold-version.sh vllm0.15-rocm7.0.0
```

This copies the latest `generic/` directory (Dockerfile **and** `versions.env`) into a
new one. In the new flow you rarely hand-edit the Dockerfile — you edit
`versions.env` (next step), and the Dockerfile consumes it via named ARGs.

---

## Step 3: Update versions.env, then triage the structural diff

The Dockerfile no longer contains hardcoded versions — every pinned value
(`MORI_BRANCH`, `FA_BRANCH`, `AITER_BRANCH`, `VLLM_REF`, `TORCH_SPEC`,
`BASE_IMAGE`, …) lives in `generic/<version>/versions.env`. An upgrade is
therefore two sub-steps: **sync the version pins**, then **triage everything
structural**.

### 3a. Sync version pins from upstream

```bash
./scripts/sync-versions.sh <version> <upstream-ref>
# e.g. ./scripts/sync-versions.sh vllm0.22-rocm7.2.2 v0.22.0
```

This reads upstream's component ARGs at that ref and writes
`versions.env.new` with the bumps applied. It:

- **auto-bumps** `FA_BRANCH`, `AITER_BRANCH`, `MORI_BRANCH` when upstream moved them;
- **leaves GPU-arch keys untouched** (`PYTORCH_ROCM_ARCH`, `*_GPU_ARCHS`,
  `*_GPU_TARGETS`) and tags them `# REVIEW` — confirm against current hardware
  (MI210=gfx90a, MI300X=gfx942, **MI350=gfx950 coming soon**);
- **prints hints** for `BASE_IMAGE` / PyTorch / Triton, which need a human to
  pick the matching Debian base + torch wheel.

Review `versions.env.new`, adjust the `# REVIEW` arch lines if hardware
changed, set `TORCH_SPEC`/`TORCH_INDEX_URL` and `BASE_IMAGE`/`ROCM_VERSION`/
`ROCM_PATH_VERSION` per the hints, then:

```bash
mv generic/<version>/versions.env.new generic/<version>/versions.env
```

### 3b. Triage the structural changes

```bash
./scripts/plan-upgrade.sh <version> <upstream-ref> <baseline-ref>
# e.g. ./scripts/plan-upgrade.sh vllm0.22-rocm7.2.2 v0.22.0 v0.14.0
```

This categorises the upstream diff so you only act on what matters:

| Category | Meaning | Action |
|---|---|---|
| `[AUTO]` | version-pin bump | already handled by 3a — just confirm |
| `[ENV]` | new ENV var | copy into the runtime ENV block if relevant (e.g. `HSA_ENABLE_IPC_MODE_LEGACY=1`) |
| `[STAGE]` | new upstream build stage | almost always **SKIP** — we only build builder/chunker/mori/fa/aiter/vllm |
| `[DEP]` | new dep inside a build step | review only if it lands in a stage we build |
| `[CONFLICT]` | touches a WMF delta (apt/repo, base, chunker, arch, perf ENV) | **hand-reconcile** — never copy blindly |

> **Note on `[STAGE]` SKIP vs its contents.** Skipping an upstream stage (e.g.
> `final`, `vllm-openai`) does *not* mean ignoring the ENV vars defined inside
> it — those surface separately under `[ENV]`. Skip the stage, but scan its ENV.

**Only edit the Dockerfile** for `[ENV]` additions and `[CONFLICT]`
reconciliation. Version bumps never require touching it. Things to preserve
through any structural edit:

- [ ] `torch-libs-chunker` stage — needed for the WMF registry layer limit
- [ ] Static library cleanup (`rm -f /opt/rocm-*/lib/*.a`)
- [ ] `torchvision` uninstall

**⚠️ PyTorch index stability:** use the stable index
(`https://download.pytorch.org/whl/rocmX.Y`), NOT nightly — nightly wheels
disappear after a few months (T385173, P87924). Verify the wheel exists:
`pip install --dry-run torch==X.Y.Z+rocmA.B --index-url ...`

---

## Step 4: Build & Smoke Test the Generic Image

```bash
# Build the generic image (takes ~3-4 hours)
time docker build --network=host \
  -t vllm-rocm-debian:<version> \
  ./generic/<version>

# Check layer sizes
docker history vllm-rocm-debian:<version> | head -25

# Smoke test with a small model
docker run --rm --network=host -it \
  --device=/dev/kfd --device=/dev/dri \
  --group-add=$(getent group video | cut -d: -f3) \
  --group-add=$(getent group render | cut -d: -f3) \
  --ipc=host \
  --security-opt seccomp=unconfined \
  -v $HOME/.cache/huggingface:/root/.cache/huggingface \
  vllm-rocm-debian:<version> /srv/venv/bin/python -c "
from vllm import LLM, SamplingParams;
llm = LLM('facebook/opt-125m');
print(llm.generate('Hello, world!', SamplingParams(max_tokens=5))[0].outputs[0].text)"
```

**Smoke test pass criteria:**
- Model downloads successfully
- vLLM engine initializes without errors
- Inference produces text output
- No ROCm/driver errors in logs

---

## Step 5: Generate the WMF Template

```bash
./scripts/generate-wmf-template.sh <version> \
  --base-tag <amd-pytorch-common-tag> \
  --rocm-suffix <NN> \
  --check wmf/<short-name>/Dockerfile.template   # optional, when updating an existing image
```

Example:

```bash
./scripts/generate-wmf-template.sh vllm0.14-rocm7.0.0 \
  --base-tag 0.0.1-2-20260118 --rocm-suffix 70 \
  --check wmf/vllm014/Dockerfile.template
```

The converter is driven by `versions.env` and applies the fixed WMF deltas
(base image, `apt.wikimedia.org` mirror, proxy ARG/ENV, `--chown=somebody`,
`USER somebody`, render-group, runtime build-dep trimming, 12 GB header). If
`--check` is given, it self-verifies that the generated template has the **same
instruction set** as the reference and reports any drift (ordering differences
are flagged as functionally equivalent, missing/extra instructions fail).

**Still review before committing:**

- [ ] Base image tag is current (`docker-registry.wikimedia.org/amd-pytorch-common/tags/`)
- [ ] `--rocm-suffix` matches the WMF mirror directory (`thirdparty/amd-rocmNN`)
- [ ] Self-check passed (set-equal; ordering-only diffs are OK)
- [ ] GPU archs in `versions.env` match current hardware (MI210/MI300X/MI350)

---

## Step 6: Update WMF APT Mirror (only if ROCm version changed)

If the ROCm version changed (e.g., 7.0.0 → 7.1.0), you need to add the new packages to the WMF APT mirror.

**Reference:** T415627#11557499, Gerrit change #1233681

1. File a puppet change against `operations/puppet@production`:
   - Update `hieradata/role/common/aptrepo.yaml` or equivalent
   - Add the new ROCm version directory/repo
2. Get it reviewed and merged by SRE
3. Verify packages are available:
   ```bash
   curl -s "http://apt.wikimedia.org/wikimedia/dists/bookworm-wikimedia/thirdparty/" | grep amd-rocm
   ```

---

## Step 7: Build WMF Image on ml-lab

```bash
# On ml-lab1002 (or equivalent):
cd /path/to/wmf/<short-name>

# Build with proxy
time docker build --network=host \
  --build-arg http_proxy="http://webproxy:8080" \
  -t wmf-vllm-image:<version> \
  .
```

**⚠️ Watch for:**
- `MAX_JOBS=1` — if not set and the machine has limited RAM (< 32GB), AITER JIT compilation can OOM. Set `--build-arg MAX_JOBS=1` if needed.
- Layer size warnings — if any single layer approaches 12GB uncompressed, it may fail to push to the WMF registry.

---

## Step 8: Validate (Benchmarks + Model Tests)

### 8a. Smoke test with a real model

```bash
docker run --rm --network=host -it \
  -e VLLM_USE_TRITON_FLASH_ATTN=0 \
  -e HF_TOKEN=<your-token> \
  --device=/dev/kfd --device=/dev/dri \
  --group-add=$(getent group video | cut -d: -f3) \
  --group-add=$(getent group render | cut -d: -f3) \
  --ipc=host \
  --security-opt seccomp=unconfined \
  -v /srv/hf-cache:/home/somebody/.cache/huggingface \
  wmf-vllm-image:<version> /srv/venv/bin/python -c "
from vllm import LLM, SamplingParams;
llm = LLM('CohereForAI/aya-expanse-8b');
print(llm.generate('Hello, vLLM!', SamplingParams(max_tokens=10))[0].outputs[0].text)"
```

### 8b. Run MAD benchmarks (optional but recommended)

Use ROCm's Model Automation and Dashboarding framework to compare throughput/latency against the previous image.

Reference: T385173#10737743, [ROCm MAD docs](https://rocm.docs.amd.com/en/docs-6.2.2/how-to/performance-validation/mi300x/vllm-benchmark.html)

### 8c. Check compressed layer sizes

Push to Docker Hub as an intermediate check (or inspect locally):

```bash
docker push kevinbazira/wmf-debian-vllm:<version>
# Then check the compressed sizes on hub.docker.com
```

The largest compressed layer must be under the WMF registry limit (currently 12GB, but aim for under 10GB to be safe).

---

## Step 9: Gerrit Changes & Deploy

### 9a. Update the WMF docker-images repo

Upload the new `Dockerfile.template` to `operations/docker-images/production-images`:

```bash
git clone "https://gerrit.wikimedia.org/r/operations/docker-images/production-images"
cd production-images
# Copy template into ml/<short-name>/Dockerfile.template
# Follow WMF commit conventions:
git commit -m "ml: update vLLM image to <version>

Why: <brief reason for upgrade>

What: <list of version changes>

Assisted-by: Claude Code <noreply@anthropic.com>
"
git review
```

Reference: Gerrit change #1237060 (T415627)

### 9b. If ROCm version changed: update puppet

File a companion puppet change to add the ROCm packages to the WMF mirror.

Reference: Gerrit change #1233681 (T415627#11557499)

### 9c. After merge

Verify the image is pullable from the WMF registry:

```bash
docker pull docker-registry.discovery.wmnet/ml/amd-vllm<NNN>:<tag>
```

### 9d. Update this repo's baseline

```bash
./scripts/check-upstream.sh --save
git add upstream/ generic/<version> wmf/<short-name>
git commit -m "add support for <version>"
```

---

## Quick Reference: Key Repos & URLs

| Resource | URL |
|---|---|
| Upstream vLLM releases | `https://github.com/vllm-project/vllm/releases` |
| Upstream ROCm Dockerfile (base) | `https://github.com/vllm-project/vllm/blob/main/docker/Dockerfile.rocm_base` |
| Upstream ROCm Dockerfile (runtime) | `https://github.com/vllm-project/vllm/blob/main/docker/Dockerfile.rocm` |
| WMF production images (Gerrit) | `operations/docker-images/production-images` |
| WMF puppet (Gerrit) | `operations/puppet@production` |
| WMF Docker registry | `docker-registry.wikimedia.org` |
| WMF APT mirror | `http://apt.wikimedia.org/wikimedia` |
| PyTorch ROCm wheels | `https://download.pytorch.org/whl/rocm<version>` |
| AMD ROCm GPU arch specs | `https://rocm.docs.amd.com/en/latest/reference/gpu-arch-specs.html` |

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| "413 Request Entity Too Large" on push | A layer exceeds WMF registry limit | Re-enable torch-libs-chunker; check `docker history` for large layers |
| `Bus error` or `SIGBUS` loading model | docker-slim over-pruned shared libs | Don't use docker-slim; rely on manual `.a` cleanup only |
| `hipblaslt` not found at runtime | Chunked libs not restored correctly | Verify `COPY --from=torch-libs-chunker` paths match `LD_LIBRARY_PATH` |
| PyTorch wheel not found | Nightly wheel was deleted from index | Switch to stable index URL (not `download.pytorch.org/whl/nightly`) |
| AITER JIT OOM during startup | Concurrent JIT compilation exhausts RAM | Set `MAX_JOBS=1` in the container environment |
| Model loads but inference is slow | AITER not being used | Set `VLLM_ROCM_USE_AITER=1` and `VLLM_USE_TRITON_FLASH_ATTN=0` |
| `amdgpu.ids: No such file or directory` | Missing firmware package (benign warning) | Can be safely ignored; only affects GPU identification strings |

---

## Appendix: Prebuilt-Wheel Investigation (closed — source build remains default)

**Date:** 2026-06-05 · **Box:** ml-lab1002 (2× AMD Instinct MI210, gfx90a) · **Verdict:** prebuilt wheels cannot replace the source build on the WMF stack today. Keep `INSTALL_METHOD=source`.

### Question

The vLLM release page advertises a one-line install:
`uv pip install vllm==X --extra-index-url https://wheels.vllm.ai/rocm/X/rocmYZZ`.
If that worked on a WMF base image it would replace the ~4 hr source build (mori → FA → aiter → vllm) with a ~20 min wheel pull. This appendix records why it does **not** work, so the spike isn't repeated.

### Two independent blockers

1. **The abi3 wheel served under `…/rocm<ver>/` is the CUDA build, not ROCm.**
   The per-version "view" `https://wheels.vllm.ai/rocm/0.22.1/rocm722/` serves `vllm-0.22.1-cp38-abi3-…whl`. Its compiled extensions are CUDA-built:
   ```
   _C.abi3.so  _C_stable_libtorch.abi3.so  _moe_C.abi3.so  _flashmla_C.abi3.so  cumem_allocator.abi3.so
   ```
   There is **no `_rocm_C.abi3.so`**. On an AMD box every extension fails to load:
   ```
   Failed to import from vllm._C with ImportError('libcudart.so.13: cannot open shared object file')
   Failed to import from vllm._rocm_C with ModuleNotFoundError("No module named 'vllm._rocm_C'")
   ```
   The wheel's true dependency closure is the CUDA stack (`torch==2.11.0` plain, `nvidia-*-cu13`, `flashinfer`) — confirming it is the CUDA artifact mislabeled by path.

2. **The genuine ROCm wheel is cp312-only.**
   The real ROCm artifact in the index is `vllm-0.22.1+rocm722-cp312` (in `rocm/vllm/`). WMF base images ship the distro-default Python: `python3-bookworm` = 3.11, `python3-trixie` = 3.13. Neither is cp312, and there is no precedent for a source-built/non-default Python in the base images. So the only real ROCm wheel can't be consumed.

Neither blocker is fixable by configuration. `VLLM_ROCM_USE_AITER` etc. are runtime kernel toggles that presuppose `_rocm_C` is already loaded; they are not platform-detection overrides. The `RuntimeError: Device string must not be empty` seen during `LLM(...)` is a downstream symptom of the missing ROCm extension, not an independent bug.

### What the spike *did* establish (keep for future use)

- ROCm 7.2 installs cleanly on `python3-bookworm` from `repo.radeon.com`. Use `rocm/apt/7.2 jammy main` only — the `amdgpu/7.2/ubuntu jammy` repo returns 404 on its Release file and is not needed (`rm /etc/apt/sources.list.d/amdgpu.list` after adding it).
- `torch==2.12.0+rocm7.2` (and `2.11.0+rocm7.2`) exist as **cp311** and **cp313** wheels at `download.pytorch.org/whl/rocm7.2`. `torch==2.10.0+rocm7.2` does **not** exist there — do not pin it. Installed torch reports `hip 7.2.53211`, `cuda None`, sees both MI210s.
- ROCm 7.2 is **not** in the WMF APT mirror (only amd-rocm63, amd-rocm70 are imported). A prebuilt mode would require an SRE puppet/aptrepo import of 7.2 for production.

### Re-evaluation trigger (when to revisit)

The prebuilt path becomes worth re-testing only if **both** hold:
1. Upstream publishes a `+rocm` wheel built for the base's actual Python (cp311 or cp313). Probe:
   ```bash
   curl -s https://wheels.vllm.ai/rocm/vllm/ | grep -oE 'cp3[0-9]+|abi3'
   ```
2. SRE imports the matching ROCm runtime into the WMF APT mirror.

If both are ever true, a known-good test recipe is: bookworm container → add `rocm/apt/7.2 jammy` → `pip install torch==<ver>+rocm7.2` (rocm index) → `pip install vllm==<ver> --no-deps` (rocm index) → verify `import vllm._rocm_C` succeeds and `LLM('facebook/opt-125m').generate(...)` runs on the MI210. The `generate-wmf-template.sh` transform needs no change — the WMF deltas (base image, apt mirror, proxy, USER, chunker) are orthogonal to install method, so a future `prebuilt` mode slots into `versions.env` without touching the WMF templating.

Until both triggers fire, prebuilt is a research note, not a pipeline mode.

---

## Appendix B: Prebuilt-Wheel Re-investigation with uv-managed Python 3.12 (2026-06-06)

**Verdict:** the prebuilt ROCm wheel path now WORKS end-to-end (generates tokens on MI210), but is **not production-viable today** — it depends on the same single gate as before (ROCm 7.2 in the WMF APT mirror) plus several non-sanctioned assembly steps. Source build remains the default. This appendix supersedes the re-evaluation trigger in Appendix A.

### What changed since Appendix A

Appendix A concluded the wheel path was blocked by two things: (1) the abi3 wheel served to Python 3.11 was the CUDA build, and (2) the genuine ROCm wheel was cp312-only. Trigger #1 in Appendix A ("upstream publishes a cp311/cp313 +rocm wheel") has NOT happened and per upstream docs will not — ROCm wheels are cp312-only by design. **However**, the cp312 constraint is defeatable with `uv`'s managed standalone Python, which Appendix A did not consider.

### Proven working recipe (on `python3-bookworm`, MI210/gfx90a)

```bash
# 1. ROCm 7.2 runtime from repo.radeon.com (NOT in WMF mirror — see gate below)
apt-get install -y gnupg ca-certificates curl
mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/rocm.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2 jammy main" \
  > /etc/apt/sources.list.d/rocm.list
apt-get update && apt-get install -y rocm-libs miopen-hip rccl rocrand

# 2. System libs the wheel's binaries link against
apt-get install -y libopenmpi3 libopenmpi-dev   # libmpi_cxx.so.40
apt-get install -y build-essential               # runtime Triton JIT needs a C/C++ compiler

# 3. uv-managed Python 3.12 (defeats the cp312-only constraint without a 3.12 base)
pip install uv --break-system-packages
uv venv /tmp/v312 --python 3.12 --seed --managed-python

# 4. The genuine ROCm wheel now resolves (cp312, +rocm722 local tag)
uv pip install vllm==0.22.1 --python /tmp/v312 \
  --extra-index-url https://wheels.vllm.ai/rocm/0.22.1/rocm722 \
  --index-strategy unsafe-best-match

# 5. Verify: _rocm_C.abi3.so present, import OK, and inference runs
/tmp/v312/bin/python -c "
from vllm import LLM, SamplingParams
llm = LLM(model='facebook/opt-125m', max_model_len=2048)
out = llm.generate(['The capital of France is'], SamplingParams(max_tokens=8))
print('GENERATE OK:', out[0].outputs[0].text)"
```

Confirmed result: `_rocm_C.abi3.so` present (the marker absent from the CUDA wheel in Appendix A), `import OK`, model loads on MI210, `torch.compile` succeeds in ~5s, `GENERATE OK` with real tokens.

### Key findings from this run

- **The cp312 block is real but `uv --managed-python` bypasses it.** uv downloads a standalone CPython 3.12 independent of the distro, so a bookworm-3.11 / trixie-3.13 base can host the cp312 wheel. The Python-version half of the problem is solved.
- **A real `0.22.1+rocm722` ROCm wheel exists.** Appendix A's reading of the upstream docs table (which lists only rocm700→0.18.0 and rocm721→nightly) implied stable wheels cap at 0.18.0. That was wrong — the per-version index `wheels.vllm.ai/rocm/0.22.1/rocm722/` serves a genuine cp312 ROCm wheel. The docs table is not the whole story; probe the per-version index directly.
- **"Prebuilt" does NOT mean "no compilation."** vLLM's `torch.compile`/Inductor path JIT-compiles Triton kernels at runtime (observed: `_compute_slot_mapping_kernel`, `_fwd_kernel`). The wheel ships AOT-compiled C++ kernels (`_rocm_C.abi3.so`) but still requires a C/C++ compiler present at inference time. The "outsource the 4-hour build" benefit is real only for the AOT portion; the image must still ship `build-essential`.
- **The wheel needs a full ROCm 7.2 host runtime it does not carry.** Missing-`.so` cascade: `libmpi_cxx.so.40` (OpenMPI) → `libroctx64.so.4` (roctracer, ROCm 7.2). The wheel assumes ROCm 7.2 is already installed on the host.

### The single production gate (unchanged)

Everything above used **non-WMF-sanctioned** components: ROCm 7.2 from `repo.radeon.com` (not the WMF mirror), and a uv-managed Python 3.12 (not a sanctioned base). For production both must be sanctioned. The binding gate is the same as Appendix A: **SRE must import ROCm 7.2 into the WMF APT mirror** (only amd-rocm63, amd-rocm70 are imported today). The Python-3.12 question becomes a second gate (sanctioned 3.12 base, or sanctioned use of uv-managed Python) — note bookworm is 3.11 and trixie is 3.13, so 3.12 is neither distro default.

### Decision criteria for when the ROCm-7.2 mirror import lands

At that point, wheel-vs-source is a genuine tradeoff to evaluate — NOT an automatic switch:

| Factor | Prebuilt wheel | Source build (current) |
| --- | --- | --- |
| Build time | Minutes (wheel pull) | ~4 hours (compile) |
| Python | Needs sanctioned 3.12 (non-default) | Builds on base's Python (3.11/3.13) |
| Runtime compiler | Required (Triton JIT) | Required anyway | 
| ROCm runtime | Must assemble on base | Assembled by Dockerfile.rocm_base |
| WMF integration | New: base, chunker, USER, mirror all need rework | Already integrated |
| Version ceiling | Whatever upstream publishes a cp312 +rocm wheel for | Any version (compiles from source) |
| gfx90a coverage | Depends on wheel's built arches | Controlled via PYTORCH_ROCM_ARCH |

The wheel saves compile time; the source build saves base-assembly and governance rework and removes the cp312/Python constraint. The pipeline (extract → verify → declared-deltas → fail-closed) is built around source and needs no change. If the wheel path is ever adopted, it slots in as an alternate `INSTALL_METHOD` in `versions.env`; the WMF deltas (base, mirror, proxy, USER, chunker) are orthogonal to install method.

### Probe to re-confirm in future

```bash
# does a genuine cp312 +rocm wheel exist for version X / rocmYZZ?
curl -s https://wheels.vllm.ai/rocm/<X>/rocm<YZZ>/vllm/ | grep -oE 'vllm-[^"<]*\.whl'
# is ROCm 7.2 (or target) now in the WMF mirror?
apt-cache policy | grep -i amd-rocm
```

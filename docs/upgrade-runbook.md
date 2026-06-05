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

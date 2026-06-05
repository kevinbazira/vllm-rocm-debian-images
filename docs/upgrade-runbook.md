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
                      │ 3. Port upstream    │  edit Dockerfile manually
                      │    changes          │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 4. Build & smoke    │  docker build + vLLM test
                      │    test generic img │
                      └────────┬────────────┘
                               │
                      ┌────────▼────────────┐
                      │ 5. Generate WMF     │  scripts/generate-wmf-template.sh
                      │    template         │
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

This copies the latest `generic/` directory into a new one. You'll update the version strings in the next step.

---

## Step 3: Port the Generic Dockerfile

Edit the new `generic/<version>/Dockerfile`. Key files to reference:

| What | Where |
|---|---|
| Upstream base | `https://github.com/vllm-project/vllm/blob/main/docker/Dockerfile.rocm_base` |
| Upstream runtime | `https://github.com/vllm-project/vllm/blob/main/docker/Dockerfile.rocm` |
| Our previous version | `generic/<previous-version>/Dockerfile` |

**Checklist of things to update:**

- [ ] `BASE_IMAGE` — Debian Bookworm snapshot date
- [ ] `ROCM_VERSION` — if ROCm version changed
- [ ] `PYTORCH_ROCM_ARCH` — ensure both gfx90a and gfx942 are listed
- [ ] PyTorch wheel URL (`--index-url`) — must match ROCm version
- [ ] PyTorch version (`torch==X.Y.Z+rocmA.B`) — must be available at the index
- [ ] `setuptools` version pin — check if upstream changed it
- [ ] MoRi commit hash (`git checkout <hash>`) — update if needed
- [ ] FlashAttention commit hash — update if needed
- [ ] aiter commit hash — update if needed (note: gfx90a currently unsupported)
- [ ] vLLM commit hash — the specific commit you are porting
- [ ] vLLM `requirements/rocm.txt` — may have new deps
- [ ] Performance env vars (`HIP_FORCE_DEV_KERNARG`, etc.) — carry over any new ones
- [ ] `torch-libs-chunker` stage — keep this; it's needed for WMF registry limits
- [ ] Static library cleanup (`rm -f /opt/rocm-*/lib/*.a`) — keep this
- [ ] `torchvision` uninstall — keep this to reduce image size

**⚠️ When ROCm version changes**, you also need:
- [ ] The new ROCm GPG key URL (verify it hasn't changed)
- [ ] The new ROCm repo path (`https://repo.radeon.com/rocm/apt/<version>`)
- [ ] Check `/opt/rocm-X.Y.Z/` path — may differ from previous version
- [ ] `amd_smi` path — typically `/opt/rocm-X.Y.Z/share/amd_smi`

**⚠️ PyTorch index stability:**
- Use the stable index (`https://download.pytorch.org/whl/rocm7.0`), NOT the nightly index.
- Nightly wheels disappear after a few months (see T385173, P87924).
- Verify the wheel exists before committing: `pip install --dry-run torch==X.Y.Z+rocmA.B --index-url ...`

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
./scripts/generate-wmf-template.sh <version>
```

This produces `wmf/<short-name>/Dockerfile.template`. **Review it carefully** — the script handles mechanical conversions but you MUST verify:

- [ ] Base image tag is current (check `docker-registry.wikimedia.org/amd-pytorch-common/tags/`)
- [ ] APT source line points to the correct WMF mirror directory
- [ ] All `COPY --from=` lines have `--chown=somebody`
- [ ] `USER somebody` is present before `pip install`
- [ ] Proxy env vars are present in both builder and runtime stages
- [ ] Runtime ROCm install is minimal (no build tools beyond what's needed for AITER JIT)
- [ ] `apt-get clean` and `rm -rf /var/lib/apt/lists/*` are present

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

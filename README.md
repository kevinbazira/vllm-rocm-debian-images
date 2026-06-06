# vLLM ROCm Debian Docker Images

![Docker](https://img.shields.io/badge/-Docker-2496ED?style=flat-square&logo=docker&logoColor=white)
[![Debian](https://img.shields.io/badge/Debian-Bookworm-A81D33?style=flat-square&logo=debian)](https://www.debian.org/)
[![ROCm](https://img.shields.io/badge/AMD-ROCm-ed1c24?style=flat-square&logo=amd)](https://rocm.docs.amd.com/)
[![vLLM](https://img.shields.io/badge/vLLM-0.8.5_to_0.22.1-blue?style=flat-square)](https://github.com/vllm-project/vllm)
[![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](https://opensource.org/licenses/MIT)

The ecosystem currently provides Ubuntu-based Docker images for AMD GPUs from both AMD ([rocm/vllm](https://hub.docker.com/r/rocm/vllm/tags)) and upstream vLLM ([vllm/vllm-openai-rocm](https://hub.docker.com/r/vllm/vllm-openai-rocm/tags)). However, for enterprise MLOps environments that prioritize extreme stability, predictability, and minimal OS footprints, [Debian](https://www.debian.org/doc/manuals/debian-faq/) is often the preferred choice.

While AMD-maintained images offer deep hardware-specific tuning and patches, the official vLLM images typically track the latest upstream features and bug fixes. By building custom images using the workflow in this repository, you achieve the best of both worlds: pairing the exact ROCm versions and AMD-specific optimizations you need with the newest upstream vLLM commits.

This repo provides optimized, production-ready Dockerfiles to build Debian-based (Bookworm) images for running vLLM on AMD Instinct GPUs.

## Key Features

**Wheel-based image (v0.22):**
* **Fast builds:** A 2-stage Dockerfile that installs the official vllm.ai pre-built ROCm wheel via `uv`. Build completes in minutes instead of hours.
* **Python 3.12 via uv:** Uses `uv venv --managed-python` to provision CPython 3.12 inside Debian Bookworm (which ships 3.11), satisfying the cp312 ABI requirement of the ROCm wheel.
* **`--index-strategy unsafe-best-match`:** Prioritizes the ROCm extra-index over PyPI so the resolver selects the genuine ROCm wheel rather than silently merging in PyPI's CUDA build ([vllm#44660](https://github.com/vllm-project/vllm/issues/44660)).
* **Minimal runtime:** The runtime stage installs only ROCm host libs, OpenMPI, and a C compiler (for Triton HIP kernel JIT at inference time). No dev headers, no build toolchains.
* **Bundled optimizations:** The pre-built wheel includes PyTorch, MoRi, FlashAttention, and aiter. No manual source compilation needed.

**Source-build images (v0.14, v0.8.5):**
* **Hardware-specific tuning:** Manual compilation of MoRi, FlashAttention, and aiter from source targeting MI210 (gfx90a) and MI300X (gfx942).
* **Registry layer chunking:** A `torch-libs-chunker` stage splits large ROCm libraries to stay under registry compressed-layer limits ([ROCm#4224](https://github.com/ROCm/ROCm/issues/4224)).

## Supported Versions

| Directory | vLLM | ROCm | Build method | Base OS | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| [`vllm0.22-rocm7.2.2/`](vllm0.22-rocm7.2.2/) | `0.22.1` | `7.2.2` | Prebuilt ROCm wheel | Bookworm | **Recommended** |
| [`vllm0.14-rocm7.0.0/`](vllm0.14-rocm7.0.0/) | `0.14.0` | `7.0.0` | Source build | Bookworm | Deprecated |
| [`vllm0.8.5-rocm6.3.0/`](vllm0.8.5-rocm6.3.0/) | `0.8.5` | `6.3.1` | Source build | Bookworm | Deprecated |

---

## Usage Guide

### 1. Build the image

Point the build context at the desired version's directory. The wheel-based build is faster because it doesn't do native kernel compilation.

**Wheel-based:**

```bash
$ time docker build --network=host \
  -t vllm-rocm-debian:vllm0.22-rocm7.2.2 \
  ./vllm0.22-rocm7.2.2

...
Successfully built 703874eb4942
Successfully tagged vllm-rocm-debian:vllm0.22-rocm7.2.2

real    11m42.156s
```

**Source-build:**

```bash
$ time docker build --network=host \
  -t vllm-rocm-debian:vllm0.14-rocm7.0.0 \
  ./vllm0.14-rocm7.0.0

...
Successfully built c7340bc54fb5
Successfully tagged vllm-rocm-debian:vllm0.14-rocm7.0.0

real    227m53.934s
```

*(If you are behind a corporate firewall, pass `--build-arg http_proxy="http://your-proxy:8080"` to the build command).*

### 2. Check uncompressed layer sizes

Enterprise docker image registries reject layers over a compressed-size limit. Inspect uncompressed sizes locally, and confirm compressed sizes too:

```bash
$ docker images
REPOSITORY               TAG                         IMAGE ID       CREATED         SIZE
vllm-rocm-debian         vllm0.22-rocm7.2.2          703874eb4942   2 hours ago    28.1GB
vllm-rocm-debian         vllm0.14-rocm7.0.0          c7340bc54fb5   13 hours ago    24.4GB


$ docker history vllm-rocm-debian:vllm0.22-rocm7.2.2
IMAGE          CREATED       CREATED BY                                      SIZE      COMMENT
703874eb4942   2 hours ago   /bin/sh -c #(nop)  ENV RAY_EXPERIMENTAL_NOSE…   0B        
954a1c17e164   2 hours ago   |3 APT_PREF=Package: *\nPin: release o=repo.…   0B        
93770cae16bd   2 hours ago   /bin/sh -c #(nop)  ENV ROCM_PATH=/opt/rocm-7…   0B        
a338cc9e80fc   2 hours ago   /bin/sh -c #(nop) COPY dir:67141d18c53f1da9e…   97.8MB    
4641e63983c5   2 hours ago   /bin/sh -c #(nop) COPY dir:800e593204f85fe74…   9.17GB    
d18201e55736   2 hours ago   |4 APT_PREF=Package: *\nPin: release o=repo.…   18.7GB    
404449834234   2 hours ago   /bin/sh -c #(nop) WORKDIR /srv                  0B        
0983b967b18e   2 hours ago   |4 APT_PREF=Package: *\nPin: release o=repo.…   1.25kB    
1d0d78a0adca   2 hours ago   /bin/sh -c #(nop)  ARG APT_PREF=Package: *\n…   0B        
58cfbc648cb7   2 hours ago   /bin/sh -c #(nop)  ARG PYTORCH_ROCM_ARCH        0B        
7df6cbb182b6   2 hours ago   /bin/sh -c #(nop)  ARG ROCM_PATH_VERSION        0B        
76e4e0ef7356   2 hours ago   /bin/sh -c #(nop)  ARG ROCM_APT_VERSION         0B        
bb1bcdc68f64   3 hours ago   /bin/sh -c #(nop)  ENV no_proxy=127.0.0.1,::…   0B        
d2dc119d4136   3 hours ago   /bin/sh -c #(nop)  ENV https_proxy=http://we…   0B        
5baba4312ad1   3 hours ago   /bin/sh -c #(nop)  ENV http_proxy=http://web…   0B        
fd6a4e097edf   2 weeks ago   # debian.sh --arch 'amd64' out/ 'bookworm' '…   117MB     debuerreotype 0.17


$ docker history vllm-rocm-debian:vllm0.14-rocm7.0.0
IMAGE          CREATED        CREATED BY                                      SIZE
c7340bc54fb5   13 hours ago   /bin/sh -c #(nop)  ENV RAY_EXPERIMENTAL_NOSE…   0B
0363f7387ac7   13 hours ago   |3 APT_PREF=Package: *\nPin: release o=repo.…   7GB
9e59135af039   13 hours ago   /bin/sh -c #(nop) COPY dir:3b9c1b68912a743d1…   71.1MB
ce5526ab55c2   13 hours ago   /bin/sh -c #(nop) COPY dir:241d1db286a481629…   479MB
d94c2dad5f54   13 hours ago   /bin/sh -c #(nop) COPY dir:291fdb658481ca532…   96.9MB
c632bc3ab4cd   13 hours ago   /bin/sh -c #(nop) COPY dir:d2fbb17f52099596c…   1.24MB
8eac695f6f64   13 hours ago   /bin/sh -c #(nop) COPY dir:438b0fe56fe1a2baa…   677MB
e279115289dd   13 hours ago   /bin/sh -c #(nop) COPY dir:4d23a33af539e2c52…   3.97GB
6be8f5dac5bc   13 hours ago   /bin/sh -c #(nop)  ARG TORCH_LIB_PATH=/srv/v…   0B
39795c13cce8   13 hours ago   /bin/sh -c #(nop) COPY dir:f286e95568f2b137e…   8.54GB
45bfc1a9ca03   13 hours ago   |2 APT_PREF=Package: *\nPin: release o=repo.…   0B
a8c05920e8b2   13 hours ago   /bin/sh -c #(nop)  ENV ROCM_PATH=/opt/rocm-7…   0B
69337e8ea420   13 hours ago   |2 APT_PREF=Package: *\nPin: release o=repo.…   3.43GB
e9d1df9bfc0c   16 hours ago   /bin/sh -c #(nop) WORKDIR /srv                  0B
83b067033467   16 hours ago   |2 APT_PREF=Package: *\nPin: release o=repo.…   1.25kB
a8a7bfe66c2c   16 hours ago   /bin/sh -c #(nop)  ARG APT_PREF=Package: *\n…   0B
40fd403f7a8c   16 hours ago   /bin/sh -c #(nop)  ARG ROCM_VERSION=7.0         0B
630a45a35d11   7 weeks ago    # debian.sh --arch 'amd64' out/ 'bookworm' '…   117MB     debuerreotype 0.17
...
```

In case a layer exceeds the docker hub/registry's layer limit size, you can use multi-stage chunking approach shown in: [`vllm0.14-rocm7.0.0/`](vllm0.14-rocm7.0.0/) to keep individual layer sizes optimized.


### 3. Run inference
You can spin up the new Debian image and test it against a lightweight model like `facebook/opt-125m` to ensure the ROCm drivers and vLLM engine are initialized correctly:

```bash
$ docker run --rm --network=host -it \
  --device=/dev/kfd --device=/dev/dri \
  --group-add=$(getent group video | cut -d: -f3) \
  --group-add=$(getent group render | cut -d: -f3) \
  --ipc=host \
  --security-opt seccomp=unconfined \
  -v $HOME/.cache/huggingface:/root/.cache/huggingface \
  vllm-rocm-debian:vllm0.22-rocm7.2.2 /srv/venv/bin/python -c "
from vllm import LLM, SamplingParams; \
llm = LLM('facebook/opt-125m'); \
print(llm.generate('Hello, world!', SamplingParams(max_tokens=5))[0].outputs[0].text)"
```

**Expected Output:**
```text
... [Engine Initialization Logs Omitted] ...
INFO 06-06 07:39:25 [model.py:617] Resolved architecture: OPTForCausalLM
INFO 06-06 07:39:25 [model.py:1752] Using max model len 2048
INFO 06-06 07:39:25 [scheduler.py:239] Chunked prefill is enabled with max_num_batched_tokens=8192.
INFO 06-06 07:39:25 [vllm.py:977] Asynchronous scheduling is enabled.
... [Engine Initialization Logs Omitted] ...
Processed prompts: 100%|███████████████████████████████████████████████████████████| 1/1 [00:01<00:00,  1.87s/it, est. speed input: 2.67 toks/s, output: 2.67 toks/s]
 That is my dad.
(EngineCore pid=543) INFO 06-06 07:39:54 [core.py:1266] Shutdown initiated (timeout=0)
(EngineCore pid=543) INFO 06-06 07:39:54 [core.py:1289] Shutdown complete
```

The first run JIT-compiles a couple of Triton kernels (a brief one-time latency spike); subsequent runs reuse the compile cache.

### 4. Bonus Tip: Optimize inference
Congratulations on successfully building and running the model-server. This is only the first step; maximizing throughput requires further optimizations. As a bonus, below is a generalized, production-tested example config used to achieve massive speedups on an MI300X (gfx942) GPU for prefill-heavy workloads (such as generating high-quality embeddings with `Qwen3-Embedding` model for: semantic search, document similarity, large-scale vector indexing, etc).

**Environment Variables (Container & Build level):**
* `VLLM_ROCM_USE_AITER=1`: Enables the AI Tensor Engine for ROCm ([AITER](https://github.com/ROCm/aiter)), which provides massive speedups via MI300X-specific matrix core optimizations.
* `VLLM_USE_TRITON_FLASH_ATTN=0`: Disables Triton-based attention to ensure the engine fully utilizes the AITER backend.
* `MAX_JOBS=1`: Restricts the `ninja` build system to a single compilation thread. JIT-compiling AITER kernels is highly memory-intensive; restricting concurrency prevents k8s pods (e.g those with 16Gi RAM limits) from triggering OOM kills during the initial startup build.

**vLLM Engine Arguments (`vllm serve ...`):**
* `--max-model-len=32768`: Matches the model's sequence length limit, enabling the indexing of entire articles/documents without losing semantic information near the end of the text.
* `--max-num-batched-tokens=32768`: Matches the model length to ensure the engine can process at least one full-length article/document in a single pass, or efficiently pack hundreds of shorter search queries together. Leaving this at the lower default can bottleneck throughput.
* `--enable-prefix-caching=False`: Disabled because embedding/search workloads typically process highly unique documents with little to no shared prompt overlap. Disabling it avoids unnecessary memory tracking overhead and frees up KV cache space for larger batches.
* `--trust-remote-code=False`: A strict security best practice for production environments. Models should be loaded from secure internal object storage (e.g Ceph/Swift) rather than directly downloading and executing arbitrary code from the HuggingFace repos at runtime.

## Upgrading

To upgrade to a new vLLM release, bump the values in the global version manifest
at the top of the Dockerfile:

```dockerfile
# Global version manifest. Bump these for upgrades.
ARG BASE_IMAGE=debian:bookworm-20260518
ARG VLLM_VERSION=0.22.1
ARG ROCM_VARIANT=rocm722
ARG ROCM_APT_VERSION=7.2
ARG ROCM_PATH_VERSION=7.2.2
ARG PYTORCH_ROCM_ARCH=gfx90a;gfx942
```

Then rebuild and smoke-test the image. For a new ROCm major version, also
update the GPG key and apt repo URL in the runtime stage.

## Final Note

I originally developed these Dockerfiles while working as a Machine Learning Engineer at the Wikimedia Foundation. Moving LLM inference workloads into production required resolving strict constraints around container OS standards (Debian) and registry compressed-layer limits, challenges that the default upstream Ubuntu images didn't address natively.

I'm sharing this repo in the hope that it saves other MLOps engineers who face similar enterprise constraints when scaling AMD ROCm and vLLM infrastructure.

If these generalized Dockerfiles help you optimize your deployment pipelines, feel free to adapt and build upon them. Happy LLM inference deploying! 🚀
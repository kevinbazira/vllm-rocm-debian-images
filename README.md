# vLLM ROCm Debian Docker Images

[![Debian](https://img.shields.io/badge/Debian-Bookworm-A81D33?style=flat-square&logo=debian)](https://www.debian.org/)
[![ROCm](https://img.shields.io/badge/AMD-ROCm-ed1c24?style=flat-square&logo=amd)](https://rocm.docs.amd.com/)
[![vLLM](https://img.shields.io/badge/vLLM-0.8.5_to_0.14-blue?style=flat-square)](https://github.com/vllm-project/vllm)
[![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](https://opensource.org/licenses/MIT)

Upstream vLLM provides [Ubuntu-based Docker images](https://hub.docker.com/r/rocm/vllm/tags) for AMD GPUs. However, for enterprise MLOps environments that prioritize extreme stability, predictability, and minimal OS footprints, [Debian](https://www.debian.org/doc/manuals/debian-faq/) is often the preferred choice.

This repo provides optimized, production-ready Dockerfiles to build Debian-based (Bookworm) images for running vLLM on AMD Instinct GPUs.

## Key Features

These Dockerfiles are generalized from production configurations used in enterprise ML environments, featuring:
* **Bypassing Docker Registry Limits:** Compiling massive AI libraries (like PyTorch with ROCm) creates Docker layers that often exceed the compressed layer limits of enterprise registries (like Harbor or AWS ECR). These images utilize a `torch-libs-chunker` multi-stage build technique to physically split `hipblaslt` and `rocblas` into smaller, manageable layers during compilation. These large ROCm packages are a known unresolved issue upstream: https://github.com/ROCm/ROCm/issues/4224
* **Hardware-Specific Tuning:** Includes manual compilation of AMD inference optimizations (like `MoRi`, `FlashAttention`, and `aiter`) natively from source targeting both MI210 (gfx90a) and MI300X (gfx942) AMD GPUs.
* **Minimal Runtime:** Uses multi-stage builds to strip out unnecessary build dependencies and static libraries (`.a` files), resulting in a lean final runtime image.

## Supported Versions

| Directory | vLLM Version | ROCm Version | PyTorch Version | Base OS | Ported Dockerfiles |
| :--- | :--- | :--- | :--- | :--- | :--- |
|[`vllm0.14-rocm7.0.0/`](vllm0.14-rocm7.0.0/) | `0.14.0` | `7.0.0` | `2.10.0+rocm7.0` | Bookworm | [Dockerfile.rocm_base](https://github.com/vllm-project/vllm/blob/6c006457123f802d78e0570471ee8ea2d2a87dfb/docker/Dockerfile.rocm_base), [Dockerfile.rocm](https://github.com/vllm-project/vllm/blob/6c006457123f802d78e0570471ee8ea2d2a87dfb/docker/Dockerfile.rocm) |
|[`vllm0.8.5-rocm6.3.0/`](vllm0.8.5-rocm6.3.0/) | `0.8.5` | `6.3.1` | `2.8.0+rocm6.3` | Bookworm | [Dockerfile.rocm_base](https://github.com/vllm-project/vllm/blob/ed6cfb90c8ad13e77dcbfa0e211075a3e2f1ee7e/docker/Dockerfile.rocm_base), [Dockerfile.rocm](https://github.com/vllm-project/vllm/blob/ed6cfb90c8ad13e77dcbfa0e211075a3e2f1ee7e/docker/Dockerfile.rocm) |

---

## Usage Guide

### 1. Build the image
To build the vllm-rocm-debian image locally, point the Docker build context to the directory of the version you wish to use.
*(Note: Building from source takes time as it compiles native ROCm kernels).*

```bash
# Example: Building the 2026 stack (vLLM 0.14 / ROCm 7.0)
$ time docker build --network=host \
  -t vllm-rocm-debian:vllm0.14-rocm7.0.0 \
  ./vllm0.14-rocm7.0.0

...
Removing intermediate container ac3898f0ad3a
 ---> c7340bc54fb5
Successfully built c7340bc54fb5
Successfully tagged vllm-rocm-debian:vllm0.14-rocm7.0.0

real    227m53.934s
user    0m2.780s
sys     0m2.875s
```
*(If you are behind a corporate firewall, you can pass `--build-arg http_proxy="http://your-proxy:8080"` to the build command).*

### 2. Check uncompressed layer sizes
You can verify the image size and view how the multi-stage chunking kept individual layer sizes optimized:

```bash
$ docker images
REPOSITORY               TAG                         IMAGE ID       CREATED         SIZE
vllm-rocm-debian         vllm0.14-rocm7.0.0          c7340bc54fb5   13 hours ago    24.4GB

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
  vllm-rocm-debian:vllm0.14-rocm7.0.0 /srv/venv/bin/python -c "
from vllm import LLM, SamplingParams; \
llm = LLM('facebook/opt-125m'); \
print(llm.generate('Hello, world!', SamplingParams(max_tokens=5))[0].outputs[0].text)"
```

**Expected Output:**
```text
INFO 03-02 06:33:41 [model.py:541] Resolved architecture: OPTForCausalLM
INFO 03-02 06:33:41 [model.py:1561] Using max model len 2048
INFO 03-02 06:33:41 [scheduler.py:226] Chunked prefill is enabled with max_num_batched_tokens=8192.
INFO 03-02 06:33:41 [vllm.py:624] Asynchronous scheduling is enabled.
... [Engine Initialization Logs Omitted] ...
Processed prompts: 100%|██████████████████████████████████████████████████████████| 1/1 [00:00<00:00,  3.10it/s, est. speed input: 15.52 toks/s, output: 15.52 toks/s]
 That is my dad.
```

## Final Note

I originally developed these Dockerfiles while working as a Machine Learning Engineer at the Wikimedia Foundation. Moving LLM inference workloads into production required resolving strict constraints around container OS standards (Debian) and registry compressed-layer limits, challenges that the default upstream Ubuntu images didn't address natively.

I'm sharing this repo in the hope that it saves other MLOps engineers who face similar enterprise constraints when scaling AMD ROCm and vLLM infrastructure.

If these generalized Dockerfiles help you optimize your deployment pipelines, feel free to adapt and build upon them. Happy LLM inference deploying! 🚀
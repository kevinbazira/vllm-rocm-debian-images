########################################################################
# debian-vllm-image: ROCm + vLLM (pre-built wheel)                     #
#                                                                      #
# Note: Multiple RUN commands are intentionally kept separate to avoid #
# hitting the 4GB (compressed) Docker layer limit required by the      #
# Wikimedia Docker registry.                                           #
########################################################################

ARG BASE_IMAGE=debian:bookworm-20260112
FROM ${BASE_IMAGE} AS builder

WORKDIR /srv

# Install Python 3 and uv for managed Python 3.12 and wheel installs
RUN apt-get update -q \
    && apt-get install -q -y --no-install-recommends python3-pip ca-certificates \
    && pip install uv --break-system-packages \
    && rm -rf /var/lib/apt/lists/*

# Create Python 3.12 venv using uv-managed CPython.
# The vLLM ROCm pre-built wheels require Python 3.12 (cp312 ABI).
ARG VLLM_VERSION
ARG ROCM_VARIANT
RUN uv venv /srv/venv --python 3.12 --seed --managed-python

# Install vLLM from the pre-built ROCm wheel.
# vllm==X.Y.Z matches X.Y.Z+rocmNNN because PEP 440 ignores local version
# tags during matching. --index-strategy unsafe-best-match prioritizes the
# extra-index over PyPI, preventing silent CUDA-wheel fallback
# (https://github.com/vllm-project/vllm/issues/44660).
RUN uv pip install vllm==${VLLM_VERSION} \
    --python /srv/venv \
    --extra-index-url "https://wheels.vllm.ai/rocm/${VLLM_VERSION}/${ROCM_VARIANT}" \
    --index-strategy unsafe-best-match

# Install AMD SMI Python interface for GPU monitoring
RUN uv pip install amdsmi --python /srv/venv


FROM ${BASE_IMAGE} AS runtime

# Mirror upstream: pin ROCm packages and create 'render' group
ARG APT_PREF="Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600"
RUN groupadd -g 109 render \
    && printf "$APT_PREF" > /etc/apt/preferences.d/rocm-pin-600

WORKDIR /srv

# Add AMD ROCm repository and install minimal runtime libs.
# build-essential provides gcc for triton HIP kernel JIT compilation.
ARG ROCM_APT_VERSION
RUN apt-get update -q \
    && apt-get install -q -y --no-install-recommends gnupg ca-certificates curl \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/rocm.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_APT_VERSION} jammy main" > /etc/apt/sources.list.d/rocm.list \
    && apt-get update -q \
    && apt-get install -q -y rocm-libs miopen-hip rccl rocrand rocm-smi-lib libopenmpi3 libopenmpi-dev build-essential \
    && apt-get purge --auto-remove -y curl gnupg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy Python venv from builder (includes vLLM, PyTorch, and all Python deps)
COPY --from=builder /srv/venv /srv/venv

# Copy uv-managed CPython 3.12 installation (required by the venv)
COPY --from=builder /root/.local/share/uv/python /root/.local/share/uv/python

# Set environment for ROCm and vLLM
ARG ROCM_PATH_VERSION
ARG PYTORCH_ROCM_ARCH
ENV ROCM_PATH=/opt/rocm-${ROCM_PATH_VERSION} \
    VLLM_TARGET_DEVICE=rocm \
    PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH} \
    PATH=/srv/venv/bin:/opt/rocm-${ROCM_PATH_VERSION}/llvm/bin:/opt/rocm-${ROCM_PATH_VERSION}/bin:${PATH} \
    LD_LIBRARY_PATH=/srv/venv/lib/python3.12/site-packages/torch/lib:/opt/rocm-${ROCM_PATH_VERSION}/lib:/usr/local/lib:

# Remove large unused static libraries (.so files are all that's needed at runtime)
RUN rm -f /opt/rocm-${ROCM_PATH_VERSION}/lib/*.a

# Set performance environment variables as defined in upstream vLLM ROCm dockerfiles
ENV RAY_EXPERIMENTAL_NOSET_ROCR_VISIBLE_DEVICES=1 \
    RAY_EXPERIMENTAL_NOSET_HIP_VISIBLE_DEVICES=1 \
    TOKENIZERS_PARALLELISM=false \
    SAFETENSORS_FAST_GPU=1 \
    HIP_FORCE_DEV_KERNARG=1 \
    HSA_NO_SCRATCH_RECLAIM=1

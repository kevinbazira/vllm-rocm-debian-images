##########################################################
# debian-vllm-image: ROCm, PyTorch, FlashAttention, vLLM #
#                                                        #
# Note: Multiple RUN commands are intentionally kept     #
# separate to avoid hitting the 4GB (compressed)         #
# Docker layer limit required by the Wikimedia Docker    #
# registry.                                              #
##########################################################

ARG BASE_IMAGE=debian:bookworm-20250428
FROM ${BASE_IMAGE} AS builder

# Mirror upstream: pin ROCm packages and create 'render' group
ARG ROCM_VERSION=6.3.1
ARG AMDGPU_VERSION=6.3.1
ARG APT_PREF="Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600"
RUN mkdir -p /app \
    && groupadd -g 109 render \
    && printf "$APT_PREF" > /etc/apt/preferences.d/rocm-pin-600
WORKDIR /app

# Add AMD ROCm & AMDGPU repositories and keys, and install ROCm libs & Python tooling
RUN mkdir -p /etc/apt/keyrings \
    && apt-get update -q \
    && apt-get install -q -y --no-install-recommends wget gnupg ca-certificates apt-transport-https \
    && wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/rocm.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${AMDGPU_VERSION}/ubuntu jammy main" > /etc/apt/sources.list.d/amdgpu.list \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} jammy main" > /etc/apt/sources.list.d/rocm.list \
    && apt-get update -q \
    && apt-get install -q -y \
       rocm \
       cmake build-essential \
       python3 python3-pip python3-dev python3-venv \
       git curl sudo vim \
       sqlite3 libsqlite3-dev libfmt-dev libmsgpack-dev libsuitesparse-dev \
    && apt-get purge --auto-remove -y wget gnupg \
    && rm -rf /var/lib/apt/lists/*

# Set environment for ROCm and vLLM
ENV ROCM_PATH=/opt/rocm \
    VLLM_TARGET_DEVICE=rocm \
    # For more details on AMD GPU architecures like gfx90a, see: https://rocm.docs.amd.com/en/latest/reference/gpu-arch-specs.html
    PYTORCH_ROCM_ARCH=gfx90a \
    PATH=/opt/rocm/llvm/bin:/opt/rocm/bin:/app/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LD_LIBRARY_PATH=/opt/rocm/lib:/usr/local/lib:

# Create a Python virtual environment and a custom temp directory
RUN python3 -m venv /app/venv \
    && mkdir -p /opt/tmp
ENV PATH="/app/venv/bin:${PATH}"
ENV TMPDIR=/opt/tmp

# Install ROCm-enabled PyTorch (into the venv)
# Using the stable index instead of the nightly index as it's more stable. (see: https://phabricator.wikimedia.org/P87924)
RUN pip install --no-cache-dir --pre torch==2.8.0+rocm6.3 \
    --index-url https://download.pytorch.org/whl/rocm6.3 \
    --extra-index-url https://pypi.org/simple

# Chunk entire hipblaslt and rocblas directories from PyTorch installation
# Define paths for clarity. Using Python 3.11 from bookworm base.
ENV TORCH_LIB_PATH="/app/venv/lib/python3.11/site-packages/torch/lib"
ENV HIPBLASLT_FULL_PATH="${TORCH_LIB_PATH}/hipblaslt"
ENV ROCBLAS_FULL_PATH="${TORCH_LIB_PATH}/rocblas"

# Create parent directory for the torch lib chunks
RUN mkdir -p /app/torch_lib_chunks

# Move the entire hipblaslt directory to the chunk location
RUN if [ -d "${HIPBLASLT_FULL_PATH}" ]; then \
        mv "${HIPBLASLT_FULL_PATH}" /app/torch_lib_chunks/hipblaslt && \
        echo "Moved ${HIPBLASLT_FULL_PATH} to /app/torch_lib_chunks/hipblaslt" ; \
    else \
        echo "Warning: Directory ${HIPBLASLT_FULL_PATH} not found." ; \
    fi

# Move the entire rocblas directory to the chunk location
RUN if [ -d "${ROCBLAS_FULL_PATH}" ]; then \
        mv "${ROCBLAS_FULL_PATH}" /app/torch_lib_chunks/rocblas && \
        echo "Moved ${ROCBLAS_FULL_PATH} to /app/torch_lib_chunks/rocblas" ; \
    else \
        echo "Warning: Directory ${ROCBLAS_FULL_PATH} not found." ; \
    fi

# Install the AMD SMI Python interface
RUN pip install --no-cache-dir /opt/rocm/share/amd_smi

# Install Python build packages required by both FlashAttention and vLLM
RUN pip install --no-cache-dir setuptools_scm packaging \
    "cmake<4" ninja wheel setuptools pybind11 Cython

# Build FlashAttention in a separate stage
FROM builder AS flashattention-builder
RUN git clone https://github.com/Dao-AILab/flash-attention.git /app/flash-attn \
    && cd /app/flash-attn \
    && git checkout 1a7f4dfa \
    && git submodule update --init \
    # For more details on AMD GPU architecures like gfx90a, see: https://rocm.docs.amd.com/en/latest/reference/gpu-arch-specs.html
    && GPU_ARCHS=gfx90a python3 setup.py bdist_wheel \
    && mkdir -p /app/wheels \
    && mv dist/*.whl /app/wheels \
    && cd /app \
    && rm -rf /app/flash-attn

# Build vLLM in a separate stage
FROM builder AS vllm-builder
ARG VLLM_REPO=https://github.com/vllm-project/vllm.git
ARG VLLM_BRANCH=main
RUN git clone --branch ${VLLM_BRANCH} ${VLLM_REPO} /app/vllm \
    && cd /app/vllm \
    && git checkout c53e073 \
    && git submodule update --init \
    && pip install --no-cache-dir -r requirements/rocm.txt \
    && python3 setup.py bdist_wheel \
    && mkdir -p /app/wheels \
    && mv dist/*.whl /app/wheels \
    && cd /app \
    && rm -rf /app/vllm

# Final stage: Create minimal runtime image
FROM ${BASE_IMAGE} AS runtime

# Copy venv (main structure; torch/lib will be missing hipblaslt and rocblas because they were moved in builder)
COPY --from=builder /app/venv /app/venv

# Define runtime paths corresponding to builder paths. Using Python 3.11 from bookworm base.
# This directory should typically exist after copying /app/venv.
ARG TORCH_LIB_PATH="/app/venv/lib/python3.11/site-packages/torch/lib"

# Copy hipblaslt and rocblas directories back into torch/lib/
COPY --from=builder /app/torch_lib_chunks/hipblaslt/ "${TORCH_LIB_PATH}/hipblaslt/"
COPY --from=builder /app/torch_lib_chunks/rocblas/ "${TORCH_LIB_PATH}/rocblas/"

# Copy pre-built wheels for FlashAttention and vLLM
COPY --from=flashattention-builder /app/wheels /app/wheels
COPY --from=vllm-builder /app/wheels /app/wheels

# Set runtime environment PATH to include venv
ENV PATH="/app/venv/bin:${PATH}"

# Install runtime dependencies and Python packages from wheels
RUN apt-get update -q \
    && apt-get install -q -y --no-install-recommends \
       python3 \
       python3-dev \
       ca-certificates \
       gcc \
       libc6-dev \
    && rm -rf /var/lib/apt/lists/* \
    # This pip install will use the venv copied above, now with PyTorch and its libraries restored
    && pip install --no-cache-dir /app/wheels/*.whl
########################################################################
# debian-vllm-image: ROCm, PyTorch, MoRi, FlashAttention, aiter, vLLM  #
#                                                                      #
# Note: Multiple RUN commands are intentionally kept separate to avoid #
# hitting the 4GB (compressed) Docker layer limit required by the      #
# Wikimedia Docker registry.                                           #
#                                                                      #
# All version-pinned values are declared as ARGs below and mirrored in #
# versions.env. Pass them with --build-arg or use the build helper.    #
# Do NOT hardcode versions in RUN lines.                               #
########################################################################

# --- version-pinned build args (defaults mirror versions.env) ---------
ARG BASE_IMAGE=debian:bookworm-20260112
ARG ROCM_VERSION=7.0
ARG ROCM_PATH_VERSION=7.0.0
ARG PYTORCH_ROCM_ARCH=gfx90a;gfx942
ARG TORCH_SPEC=torch==2.10.0+rocm7.0
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/rocm7.0
ARG MORI_BRANCH=2d02c6a9
ARG MORI_GPU_TARGETS=gfx90a;gfx942
ARG FA_BRANCH=0e60e394
ARG FA_GPU_ARCHS=gfx90a;gfx942
ARG AITER_BRANCH=6af8b687
ARG AITER_GPU_ARCHS=gfx942
ARG VLLM_REF=6c0064571
ARG VLLM_GPU_ARCHS=gfx90a;gfx942

FROM ${BASE_IMAGE} AS builder

# Mirror upstream: pin ROCm packages and create 'render' group
ARG ROCM_VERSION
ARG APT_PREF="Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600"
RUN groupadd -g 109 render \
    && printf "$APT_PREF" > /etc/apt/preferences.d/rocm-pin-600
WORKDIR /srv

# Add AMD ROCm repositories and keys, and install ROCm libs & Python tooling
RUN mkdir -p /etc/apt/keyrings \
    && apt-get update -q \
    && apt-get install -q -y --no-install-recommends wget gnupg ca-certificates apt-transport-https \
    && wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/rocm.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${ROCM_VERSION}/ubuntu jammy main" > /etc/apt/sources.list.d/amdgpu.list \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} jammy main" > /etc/apt/sources.list.d/rocm.list \
    && apt-get update -q \
    && apt-get install -q -y \
    libopenmpi-dev libpci-dev hsa-rocr-dev miopen-hip mivisionx radeontop rccl rocblas rocfft rocm-cmake rocm-dev rocm-device-libs rocm-libs rocm-opencl rocm-opencl-dev rocm-utils rocrand rocm-smi-lib migraphx cmake build-essential python3-dev python3-venv git curl sudo vim sqlite3 libsqlite3-dev libfmt-dev libmsgpack-dev libsuitesparse-dev \
    && apt-get purge --auto-remove -y wget gnupg \
    && rm -rf /var/lib/apt/lists/*

# Set environment for ROCm and vLLM
ARG ROCM_PATH_VERSION
ARG PYTORCH_ROCM_ARCH
ENV ROCM_PATH=/opt/rocm-${ROCM_PATH_VERSION} \
    VLLM_TARGET_DEVICE=rocm \
    # For more details on AMD GPU architectures like gfx90a, see: https://rocm.docs.amd.com/en/latest/reference/gpu-arch-specs.html
    PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH} \
    PATH=/opt/rocm-${ROCM_PATH_VERSION}/llvm/bin:/opt/rocm-${ROCM_PATH_VERSION}/bin:/srv/venv/bin:$PATH \
    # LD_LIBRARY_PATH is needed to ensure that the runtime can locate shared libraries in non-standard directories, such as /opt/rocm-7.0.0/lib and /usr/local/lib, which are required by ROCm and other dependencies.
    LD_LIBRARY_PATH=/opt/rocm-${ROCM_PATH_VERSION}/lib:/usr/local/lib:

# Create a Python virtual environment and a custom temp directory
RUN python3 -m venv /srv/venv \
    && mkdir -p /opt/tmp
ENV PATH="/srv/venv/bin:${PATH}"
ENV TMPDIR=/opt/tmp

# Install ROCm-enabled PyTorch (into the venv)
# Using the stable index instead of the nightly index as it's more stable. (see: https://phabricator.wikimedia.org/P87924)
ARG TORCH_SPEC
ARG TORCH_INDEX_URL
RUN pip install --no-cache-dir --pre ${TORCH_SPEC} \
    --index-url ${TORCH_INDEX_URL} \
    --extra-index-url https://pypi.org/simple   

# Install the AMD SMI Python interface
RUN pip install --no-cache-dir /opt/rocm-${ROCM_PATH_VERSION}/share/amd_smi

# Install Python build packages required by both FlashAttention and vLLM
RUN pip install --no-cache-dir setuptools_scm packaging \
    "cmake<4" ninja wheel "setuptools<80" pybind11 Cython

# Chunck torch libs (hipblaslt and rocblas) because they are large. 
# The goal is to copy them separately in the runtime stage to avoid hitting 
# the compressed layer limit in the Wikimedia Docker registry.
# (see: https://phabricator.wikimedia.org/T415627#11594815)
FROM builder AS torch-libs-chunker
# Chunk entire hipblaslt and rocblas directories from PyTorch installation
# Define paths for clarity. Using Python 3.11 from bookworm base.
ENV TORCH_LIB_PATH="/srv/venv/lib/python3.11/site-packages/torch/lib"
ENV HIPBLASLT_FULL_PATH="${TORCH_LIB_PATH}/hipblaslt"
ENV ROCBLAS_FULL_PATH="${TORCH_LIB_PATH}/rocblas"    

# Create parent directory for the torch lib chunks
RUN mkdir -p /srv/torch_lib_chunks

# Move the entire hipblaslt directory to the chunk location
RUN if [ -d "${HIPBLASLT_FULL_PATH}" ]; then \
        mv "${HIPBLASLT_FULL_PATH}" /srv/torch_lib_chunks/hipblaslt && \
        echo "Moved ${HIPBLASLT_FULL_PATH} to /srv/torch_lib_chunks/hipblaslt" ; \
    else \
        echo "Warning: Directory ${HIPBLASLT_FULL_PATH} not found." ; \
    fi

# Move the entire rocblas directory to the chunk location
RUN if [ -d "${ROCBLAS_FULL_PATH}" ]; then \
        mv "${ROCBLAS_FULL_PATH}" /srv/torch_lib_chunks/rocblas && \
        echo "Moved ${ROCBLAS_FULL_PATH} to /srv/torch_lib_chunks/rocblas" ; \
    else \
        echo "Warning: Directory ${ROCBLAS_FULL_PATH} not found." ; \
    fi

# Build MoRI in a separate stage
FROM builder AS mori-builder
ARG MORI_BRANCH
ARG MORI_GPU_TARGETS
RUN git clone https://github.com/ROCm/mori.git /srv/mori \
    && cd /srv/mori \
    && git checkout ${MORI_BRANCH} \
    && git submodule update --init --recursive \
    && GPU_TARGETS="${MORI_GPU_TARGETS}" python3 setup.py bdist_wheel \
    && mkdir -p /srv/wheels \
    && mv dist/*.whl /srv/wheels \
    && cd /srv \
    && rm -rf /srv/mori

# Build FlashAttention in a separate stage
FROM builder AS flashattention-builder
ARG FA_BRANCH
ARG FA_GPU_ARCHS
RUN git clone https://github.com/Dao-AILab/flash-attention.git /srv/flash-attn \
    && cd /srv/flash-attn \
    && git checkout ${FA_BRANCH} \
    && git submodule update --init \
    # For more details on AMD GPU architectures like gfx90a, see: https://rocm.docs.amd.com/en/latest/reference/gpu-arch-specs.html
    && GPU_ARCHS="${FA_GPU_ARCHS}" python3 setup.py bdist_wheel \
    && mkdir -p /srv/wheels \
    && mv dist/*.whl /srv/wheels \
    && cd /srv \
    && rm -rf /srv/flash-attn

# Build aiter in a separate stage
FROM builder AS aiter-builder
ARG AITER_BRANCH
ARG AITER_GPU_ARCHS
RUN git clone https://github.com/ROCm/aiter.git /srv/aiter \
    && cd /srv/aiter \
    && git checkout ${AITER_BRANCH} \
    && git submodule sync \
    && git submodule update --init --recursive \
    && pip install -r requirements.txt \
    # Currently doesn't support gfx90a. (see: https://phabricator.wikimedia.org/P88226)
    && PREBUILD_KERNELS=1 GPU_ARCHS=${AITER_GPU_ARCHS} python3 setup.py bdist_wheel \
    && mkdir -p /srv/wheels \
    && mv dist/*.whl /srv/wheels \
    && cd /srv \
    && rm -rf /srv/aiter

# Build vLLM in a separate stage
FROM builder AS vllm-builder
ARG VLLM_REF
ARG VLLM_GPU_ARCHS
RUN git clone --branch main https://github.com/vllm-project/vllm.git /srv/vllm \
    && cd /srv/vllm \
    && git checkout ${VLLM_REF} \
    && git submodule update --init \
    && pip install --no-cache-dir -r requirements/rocm.txt \
    && GPU_ARCHS="${VLLM_GPU_ARCHS}" python3 setup.py bdist_wheel \
    && mkdir -p /srv/wheels \
    && mv dist/*.whl /srv/wheels \
    && cd /srv \
    && rm -rf /srv/vllm

# Final stage: Create minimal runtime image
FROM  ${BASE_IMAGE} as runtime

# Mirror upstream: pin ROCm packages and create 'render' group
ARG ROCM_VERSION
ARG APT_PREF="Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600"
RUN groupadd -g 109 render \
    && printf "$APT_PREF" > /etc/apt/preferences.d/rocm-pin-600
WORKDIR /srv

# Add AMD ROCm repositories and keys, and install minimal runtime ROCm libs and Python tooling
# Also install ROCm build dependencies to support AITER kernel compilation. (see: https://phabricator.wikimedia.org/T419650)
RUN mkdir -p /etc/apt/keyrings \
    && apt-get update -q \
    && apt-get install -q -y --no-install-recommends wget gnupg ca-certificates apt-transport-https \
    && wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/rocm.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${ROCM_VERSION}/ubuntu jammy main" > /etc/apt/sources.list.d/amdgpu.list \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} jammy main" > /etc/apt/sources.list.d/rocm.list \
    && apt-get update -q \
    && apt-get install -q -y \
    libopenmpi-dev libpci-dev libc6-dev rocm-smi-lib hip-dev rccl python3-dev ca-certificates gcc \
    libdrm-amdgpu1 g++ rocm-dev rocm-device-libs hipsparse-dev rocthrust-dev rocprim-dev rocblas-dev hipblas-dev rocsparse-dev hipblaslt-dev hipsolver-dev \
    && apt-get purge --auto-remove -y wget gnupg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set environment for ROCm and vLLM
ARG ROCM_PATH_VERSION
ENV ROCM_PATH=/opt/rocm-${ROCM_PATH_VERSION} \
    ROCM_HOME=/opt/rocm-${ROCM_PATH_VERSION} \
    VLLM_TARGET_DEVICE=rocm \
    PATH=/opt/rocm-${ROCM_PATH_VERSION}/llvm/bin:/opt/rocm-${ROCM_PATH_VERSION}/bin:/srv/venv/bin:$PATH \
    # LD_LIBRARY_PATH is needed to ensure that the runtime can locate shared libraries in non-standard directories, such as /opt/rocm-7.0.0/lib and /usr/local/lib, which are required by ROCm and other dependencies.
    LD_LIBRARY_PATH=/srv/venv/lib/python3.11/site-packages/torch/lib:/opt/rocm-${ROCM_PATH_VERSION}/lib:/usr/local/lib:

# Remove large unused static libraries
# We only need the .so files for runtime inference.
RUN rm -f /opt/rocm-${ROCM_PATH_VERSION}/lib/*.a

# Copy venv (main structure; torch/lib will be missing hipblaslt and rocblas because they were moved in torch-libs-chunker stage)
COPY --from=torch-libs-chunker /srv/venv /srv/venv

# Define runtime paths corresponding to torch-libs-chunker paths. Using builder's Python 3.11 from bookworm base.
# This directory should typically exist after copying /srv/venv.
ARG TORCH_LIB_PATH="/srv/venv/lib/python3.11/site-packages/torch/lib"

# Restore hipblaslt and rocblas directories to torch/lib/ for ROCm-enabled PyTorch functionality
COPY --from=torch-libs-chunker /srv/torch_lib_chunks/hipblaslt/ "${TORCH_LIB_PATH}/hipblaslt/"
COPY --from=torch-libs-chunker /srv/torch_lib_chunks/rocblas/ "${TORCH_LIB_PATH}/rocblas/"

# Copy pre-built wheels for MoRI, FlashAttention, aiter, and vLLM
COPY --from=mori-builder /srv/wheels /srv/wheels
COPY --from=flashattention-builder /srv/wheels /srv/wheels
COPY --from=aiter-builder /srv/wheels /srv/wheels
COPY --from=vllm-builder /srv/wheels /srv/wheels

# Install Python packages from wheels and uninstall unused package torchvision
RUN pip install --no-cache-dir /srv/wheels/*.whl \
    && pip uninstall -y torchvision \
    # To reduce the image size, remove the wheel files as they are no longer needed
    && rm -rf /srv/wheels/*

# Set performance environment variables as defined in upstream vLLM ROCm dockerfiles
ENV RAY_EXPERIMENTAL_NOSET_ROCR_VISIBLE_DEVICES=1 \
    RAY_EXPERIMENTAL_NOSET_HIP_VISIBLE_DEVICES=1 \
    TOKENIZERS_PARALLELISM=false \
    # ENV that can improve safe tensor loading, and end-to-end time
    SAFETENSORS_FAST_GPU=1 \
    # Performance environment variable.
    HIP_FORCE_DEV_KERNARG=1 \
    # Required for RCCL in ROCm7.1 (kept this because it also exists in the rocm/vllm:v0.14.0_amd_dev docker image that runs ROCm7.0)
    HSA_NO_SCRATCH_RECLAIM=1

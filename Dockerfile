# -----------------------------------------------------------------------------
# Image for Paperspace Notebook (GPU) running JupyterLab + ComfyUI
# Customized for personal/private use on Paperspace
# -----------------------------------------------------------------------------
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

LABEL maintainer="mochidroppot <mochidroppot@gmail.com>"

# ------------------------------
# Build-time and runtime settings
# ------------------------------
ARG PYTHON_VERSION=3.11
ARG MAMBA_USER=mambauser

ENV MAMBA_USER=${MAMBA_USER} \
    DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    SHELL=/bin/bash \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    MAMBA_ROOT_PREFIX=/opt/conda \
    CONDA_DEFAULT_ENV=pyenv \
    HF_HOME=/storage/sd-suite/hf_cache \
    COMFYUI_AUTO_UPDATE=0 \
    COMFYUI_CUSTOM_NODES_AUTO_UPDATE=0 \
    COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS=0

# ------------------------------
# Base packages
# ------------------------------
RUN set -eux; \
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"; \
    { \
      echo "deb https://archive.ubuntu.com/ubuntu ${codename} main universe multiverse restricted"; \
      echo "deb https://archive.ubuntu.com/ubuntu ${codename}-updates main universe multiverse restricted"; \
      echo "deb https://security.ubuntu.com/ubuntu ${codename}-security main universe multiverse restricted"; \
    } > /etc/apt/sources.list; \
    apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout="30" update && \
    apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout="30" install -y --no-install-recommends \
      ca-certificates curl wget git git-lfs nano vim zip unzip tzdata build-essential \
      libgl1-mesa-glx libglib2.0-0 openssh-client bzip2 pkg-config iproute2 tini ffmpeg \
      aria2 rsync jq && \
    rm -rf /var/lib/apt/lists/*

# ------------------------------
# micromamba (system-wide)
# ------------------------------
RUN set -eux; \
    mkdir -p ${MAMBA_ROOT_PREFIX}; \
    curl -fsSL -o /tmp/micromamba.tar.bz2 "https://micro.mamba.pm/api/micromamba/linux-64/latest"; \
    if tar -tjf /tmp/micromamba.tar.bz2 | grep -q '^bin/micromamba$'; then \
      tar -xjf /tmp/micromamba.tar.bz2 -C /usr/local/bin --strip-components=1 bin/micromamba; \
    else \
      echo "micromamba tar layout unexpected; falling back to install.sh"; \
      curl -fsSL -o /tmp/install_micromamba.sh https://micro.mamba.pm/install.sh; \
      bash /tmp/install_micromamba.sh -b -p ${MAMBA_ROOT_PREFIX}; \
      ln -sf ${MAMBA_ROOT_PREFIX}/bin/micromamba /usr/local/bin/micromamba; \
    fi; \
    micromamba --version; \
    echo "export PATH=${MAMBA_ROOT_PREFIX}/bin:\$PATH" > /etc/profile.d/mamba.sh

# ------------------------------
# Python environment
# ------------------------------
RUN set -eux; \
    micromamba create -y -p ${MAMBA_ROOT_PREFIX}/envs/pyenv python=${PYTHON_VERSION}; \
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv python -m pip install --upgrade pip setuptools wheel && \
    micromamba clean -a -y

ENV PATH=${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}

# ------------------------------
# Application: ComfyUI
# ------------------------------
RUN set -eux; \
    git clone https://github.com/comfyanonymous/ComfyUI.git /opt/app/ComfyUI && \
    mkdir -p /opt/app/ComfyUI/custom_nodes && \
    git clone https://github.com/Comfy-Org/ComfyUI-Manager.git /opt/app/ComfyUI/custom_nodes/ComfyUI-Manager && \
    git clone https://github.com/mit-han-lab/ComfyUI-nunchaku.git /opt/app/ComfyUI/custom_nodes/nunchaku_nodes && \
    git clone https://github.com/mochidroppot/ComfyUI-ProxyFix.git /opt/app/ComfyUI/custom_nodes/ComfyUI-ProxyFix && \
    git config --global --add safe.directory /opt/app/ComfyUI

# ------------------------------
# Custom nodes requested by user
# clone only; dependency install is deferred until after startup
# ------------------------------
RUN set -eux; \
    cd /opt/app/ComfyUI/custom_nodes && \
    git clone https://github.com/city96/ComfyUI-GGUF.git || true && \
    git clone https://github.com/DoctorDiffusion/ComfyUI-MediaMixer.git || true && \
    git clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git || true && \
    git clone https://github.com/rgthree/rgthree-comfy.git || true && \
    git clone https://github.com/jamesWalker55/comfyui-various.git || true && \
    git clone https://github.com/Smirnov75/ComfyUI-mxToolkit.git || true && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git || true && \
    git clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git || true && \
    git clone https://github.com/kijai/ComfyUI-KJNodes.git || true && \
    git clone https://github.com/WASasquatch/was-node-suite-comfyui.git || true

# ------------------------------
# PyTorch + core libs + base ComfyUI requirements only
# ------------------------------
RUN set -eux; \
    export PIP_NO_CACHE_DIR=0; \
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install --index-url https://download.pytorch.org/whl/cu124 torch torchvision torchaudio && \
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install --prefer-binary --upgrade-strategy only-if-needed \
      jupyterlab==4.* notebook ipywidgets jupyterlab-git jupyter-server-proxy tensorboard \
      matplotlib pandas numpy scipy tqdm rich supervisor \
      huggingface_hub safetensors opencv-python pillow requests einops pyyaml psutil && \
    if [ -f /opt/app/ComfyUI/requirements.txt ]; then \
      micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install -r /opt/app/ComfyUI/requirements.txt; \
    fi; \
    if [ -f /opt/app/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt ]; then \
      micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install -r /opt/app/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt; \
    fi; \
    if [ -f /opt/app/ComfyUI/custom_nodes/ComfyUI-ProxyFix/requirements.txt ]; then \
      micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install -r /opt/app/ComfyUI/custom_nodes/ComfyUI-ProxyFix/requirements.txt; \
    fi; \
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv python -m pip install https://github.com/nunchaku-tech/nunchaku/releases/download/v1.0.0/nunchaku-1.0.0+torch2.6-cp311-cp311-linux_x86_64.whl; \
    micromamba clean -a -y

# ------------------------------
# Download extension wheel only
# ------------------------------
RUN set -eux; \
    mkdir -p /opt/app/jlab_extensions && \
    curl -fsSL -o /opt/app/jlab_extensions/jupyterlab_comfyui_cockpit-0.1.0-py3-none-any.whl \
      https://github.com/mochidroppot/jupyterlab-comfyui-cockpit/releases/download/v0.1.0/jupyterlab_comfyui_cockpit-0.1.0-py3-none-any.whl

# ------------------------------
# Non-root user
# ------------------------------
RUN set -eux; \
    useradd -m -s /bin/bash ${MAMBA_USER}; \
    mkdir -p /workspace /workspace/data /workspace/notebooks; \
    mkdir -p /storage/sd-suite/comfyui /storage/sd-suite/hf_cache; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} /home/${MAMBA_USER}; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} ${MAMBA_ROOT_PREFIX}; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} /opt/app; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} /workspace; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} /storage

USER ${MAMBA_USER}
RUN git config --global --add safe.directory /opt/app/ComfyUI

USER root

# ------------------------------
# Healthcheck
# ------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD bash -lc 'ss -ltn | grep -E ":8888" >/dev/null || exit 1'

# ------------------------------
# Entrypoint / runtime scripts
# ------------------------------
WORKDIR /notebooks

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/install_custom_node_deps.sh /usr/local/bin/install_custom_node_deps.sh
COPY config/supervisord.conf /etc/supervisord.conf

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/install_custom_node_deps.sh && \
    chown ${MAMBA_USER}:${MAMBA_USER} /usr/local/bin/entrypoint.sh /usr/local/bin/install_custom_node_deps.sh

# ------------------------------
# Install local package
# ------------------------------
COPY pyproject.toml /tmp/paperspace-stable-diffusion-suite/pyproject.toml
COPY src /tmp/paperspace-stable-diffusion-suite/src
RUN micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install /tmp/paperspace-stable-diffusion-suite && \
    rm -rf /tmp/paperspace-stable-diffusion-suite

# ------------------------------
# Ports
# ------------------------------
EXPOSE 8888
EXPOSE 8189

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

USER ${MAMBA_USER}
ENV PATH=${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}

# Default command (JupyterLab)
CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--ServerApp.token="]

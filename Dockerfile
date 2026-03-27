# -----------------------------------------------------------------------------
# Image for Paperspace Notebook (GPU) running JupyterLab + ComfyUI
# Customized for personal/private use on Paperspace
# -----------------------------------------------------------------------------
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

LABEL maintainer="mochidroppot"

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
    HF_HOME=/opt/app/hf_home \
    HF_HUB_CACHE=/opt/app/hf_home/hub \
    HF_ASSETS_CACHE=/opt/app/hf_home/assets \
    HF_XET_CACHE=/opt/app/hf_home/xet \
    TRANSFORMERS_CACHE=/opt/app/hf_home/transformers \
    COMFYUI_AUTO_UPDATE=0 \
    COMFYUI_CUSTOM_NODES_AUTO_UPDATE=0 \
    COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS=0 \
    COMFYUI_PORT=8189 \
    COMFYUI_LISTEN_HOST=0.0.0.0 \
    COMFYUI_EXTRA_ARGS="--disable-auto-launch --preview-method none --force-fp16 --use-split-cross-attention"

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
      ca-certificates curl wget git nano vim zip unzip tzdata build-essential \
      libgl1-mesa-glx libglib2.0-0 openssh-client bzip2 pkg-config iproute2 tini ffmpeg \
      supervisor && \
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
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv python -m pip install --upgrade pip && \
    micromamba clean -a -y

ENV PATH=${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}

# ------------------------------
# Application: ComfyUI
# ------------------------------
RUN set -eux; \
    git clone https://github.com/comfyanonymous/ComfyUI.git /opt/app/ComfyUI && \
    mkdir -p /opt/app/ComfyUI/custom_nodes && \
    git config --global --add safe.directory /opt/app/ComfyUI

# ここに必要な custom_nodes を追加
# 例:
# RUN set -eux; \
#     git clone https://github.com/Comfy-Org/ComfyUI-Manager.git /opt/app/ComfyUI/custom_nodes/ComfyUI-Manager

# ------------------------------
# Core Python packages
# ------------------------------
RUN set -eux; \
    export PIP_NO_CACHE_DIR=0; \
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install --index-url https://download.pytorch.org/whl/cu124 torch torchvision torchaudio && \
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install --prefer-binary --upgrade-strategy only-if-needed \
      jupyterlab==4.* notebook ipywidgets jupyterlab-git jupyter-server-proxy tensorboard \
      matplotlib seaborn pandas numpy scipy tqdm rich requests pyyaml && \
    if [ -f /opt/app/ComfyUI/requirements.txt ]; then \
      micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install -r /opt/app/ComfyUI/requirements.txt; \
    fi; \
    micromamba clean -a -y

# ------------------------------
# ComfyUI model directories and temporary HF cache
# ------------------------------
RUN set -eux; \
    mkdir -p \
      /opt/app/hf_home \
      /opt/app/ComfyUI/models \
      /opt/app/ComfyUI/models/checkpoints \
      /opt/app/ComfyUI/models/clip \
      /opt/app/ComfyUI/models/clip_vision \
      /opt/app/ComfyUI/models/configs \
      /opt/app/ComfyUI/models/controlnet \
      /opt/app/ComfyUI/models/diffusers \
      /opt/app/ComfyUI/models/diffusion_models \
      /opt/app/ComfyUI/models/embeddings \
      /opt/app/ComfyUI/models/gligen \
      /opt/app/ComfyUI/models/hypernetworks \
      /opt/app/ComfyUI/models/loras \
      /opt/app/ComfyUI/models/style_models \
      /opt/app/ComfyUI/models/text_encoders \
      /opt/app/ComfyUI/models/unet \
      /opt/app/ComfyUI/models/upscale_models \
      /opt/app/ComfyUI/models/vae \
      /opt/app/ComfyUI/input \
      /opt/app/ComfyUI/output \
      /opt/app/ComfyUI/temp

# ------------------------------
# Non-root user
# ------------------------------
RUN set -eux; \
    useradd -m -s /bin/bash ${MAMBA_USER}; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} /home/${MAMBA_USER}; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} ${MAMBA_ROOT_PREFIX}; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} /opt/app

USER ${MAMBA_USER}
RUN git config --global --add safe.directory /opt/app/ComfyUI

USER root

# ------------------------------
# Workspace
# ------------------------------
RUN set -eux; \
    mkdir -p /workspace /workspace/data /workspace/notebooks /notebooks /storage; \
    mkdir -p /notebooks/ComfyUI; \
    rm -rf /notebooks/ComfyUI/models; \
    ln -s /opt/app/ComfyUI/models /notebooks/ComfyUI/models; \
    chown -R ${MAMBA_USER}:${MAMBA_USER} /workspace /notebooks /storage

USER ${MAMBA_USER}

ENV PATH=${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}
ENV CONDA_DEFAULT_ENV=pyenv

# ------------------------------
# Healthcheck
# ------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD bash -lc 'ss -ltn | grep -E ":8888" >/dev/null || exit 1'

USER root
WORKDIR /notebooks

# ------------------------------
# Entrypoint / startup
# ------------------------------
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh && \
    chown ${MAMBA_USER}:${MAMBA_USER} /usr/local/bin/entrypoint.sh

# 必要なら supervisord を使う場合に有効化
# COPY config/supervisord.conf /etc/supervisord.conf

EXPOSE 8888

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

USER ${MAMBA_USER}

CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--ServerApp.token=", "--ServerApp.password="]

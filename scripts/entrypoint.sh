#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== paperspace-stable-diffusion-suite: entrypoint start ==="

# ----------------------------------------
# Basic paths / env
# ----------------------------------------
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/conda}"
COMFYUI_APP_BASE="${COMFYUI_APP_BASE:-/opt/app/ComfyUI}"
STORAGE_BASE="${STORAGE_BASE:-/storage/sd-suite}"
STORAGE_COMFYUI_DIR="${STORAGE_COMFYUI_DIR:-${STORAGE_BASE}/comfyui}"
JLAB_EXTENSIONS_DIR="${JLAB_EXTENSIONS_DIR:-${STORAGE_BASE}/jlab_extensions}"
HF_HOME="${HF_HOME:-${STORAGE_BASE}/hf_cache}"

COMFYUI_PORT="${COMFYUI_PORT:-8189}"
COMFYUI_LISTEN_HOST="${COMFYUI_LISTEN_HOST:-0.0.0.0}"
COMFYUI_EXTRA_ARGS="${COMFYUI_EXTRA_ARGS:---disable-auto-launch --preview-method auto}"

COMFYUI_AUTO_UPDATE="${COMFYUI_AUTO_UPDATE:-0}"
COMFYUI_CUSTOM_NODES_AUTO_UPDATE="${COMFYUI_CUSTOM_NODES_AUTO_UPDATE:-0}"
COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS="${COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS:-1}"

export PATH="${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}"
export HF_HOME
export COMFYUI_PORT
export COMFYUI_LISTEN_HOST
export COMFYUI_EXTRA_ARGS

# ----------------------------------------
# Helper functions
# ----------------------------------------
run_as_mambauser() {
  su - "${MAMBA_USER:-mambauser}" -s /bin/bash -c "$*"
}

link_dir() {
  local src="$1"
  local dst="$2"

  mkdir -p "$(dirname "$src")"
  mkdir -p "$dst"

  if [ -L "$src" ]; then
    return 0
  fi

  if [ -d "$src" ] && [ ! -L "$src" ]; then
    # 中身があれば退避
    if [ -n "$(ls -A "$src" 2>/dev/null || true)" ] && [ -z "$(ls -A "$dst" 2>/dev/null || true)" ]; then
      echo "Syncing existing contents: $src -> $dst"
      rsync -a "$src"/ "$dst"/ || true
    fi
    rm -rf "$src"
  elif [ -e "$src" ]; then
    rm -rf "$src"
  fi

  ln -s "$dst" "$src"
}

clone_or_update_repo() {
  local repo_url="$1"
  local base_dir="$2"
  local repo_name
  repo_name="$(basename "$repo_url" .git)"
  local repo_dir="${base_dir}/${repo_name}"

  if [ -d "${repo_dir}/.git" ]; then
    echo
    echo "=== Updating existing repo: ${repo_name} ==="
    if [ "$COMFYUI_CUSTOM_NODES_AUTO_UPDATE" = "1" ]; then
      echo "[RUN] git pull"
      run_as_mambauser "cd '${repo_dir}' && git pull --ff-only" || true
    else
      echo "Skip update: COMFYUI_CUSTOM_NODES_AUTO_UPDATE=${COMFYUI_CUSTOM_NODES_AUTO_UPDATE}"
    fi
  else
    echo
    echo "=== Cloning repo: ${repo_name} ==="
    run_as_mambauser "cd '${base_dir}' && git clone '${repo_url}'" || true
  fi
}

install_custom_node_deps() {
  echo
  echo "=== Installing custom node dependencies ==="

  local req
  while IFS= read -r -d '' req; do
    echo "[requirements] $req"
    pip install -r "$req" || true
  done < <(find "${COMFYUI_APP_BASE}/custom_nodes" -maxdepth 2 -name requirements.txt -print0)

  local pyproject
  while IFS= read -r -d '' pyproject; do
    local proj_dir
    proj_dir="$(dirname "$pyproject")"
    echo "[pyproject] $proj_dir"
    (
      cd "$proj_dir"
      pip install .
    ) || true
  done < <(find "${COMFYUI_APP_BASE}/custom_nodes" -maxdepth 2 -name pyproject.toml -print0)
}

install_jlab_extension_if_present() {
  local wheel="/opt/app/jlab_extensions/jupyterlab_comfyui_cockpit-0.1.0-py3-none-any.whl"
  if [ -f "$wheel" ]; then
    echo
    echo "=== Installing JupyterLab extension wheel ==="
    pip install "$wheel" || true
  fi
}

# ----------------------------------------
# Prepare persistent storage
# ----------------------------------------
echo
echo "=== Preparing persistent directories ==="

mkdir -p "${STORAGE_COMFYUI_DIR}/input" \
         "${STORAGE_COMFYUI_DIR}/output" \
         "${STORAGE_COMFYUI_DIR}/custom_nodes" \
         "${STORAGE_COMFYUI_DIR}/user" \
         "${STORAGE_COMFYUI_DIR}/models" \
         "${JLAB_EXTENSIONS_DIR}" \
         "${HF_HOME}" \
         /workspace \
         /workspace/data \
         /workspace/notebooks

chown -R "${MAMBA_USER:-mambauser}:${MAMBA_USER:-mambauser}" "${STORAGE_BASE}" /workspace || true

# link comfyui subdirs to persistent storage
for d in input output custom_nodes user models; do
  link_dir "${COMFYUI_APP_BASE}/${d}" "${STORAGE_COMFYUI_DIR}/${d}"
done

# optional: persist downloaded jupyter extension wheels
if [ -d /opt/app/jlab_extensions ]; then
  rsync -a /opt/app/jlab_extensions/ "${JLAB_EXTENSIONS_DIR}/" || true
fi

# ----------------------------------------
# ComfyUI repo update (optional)
# ----------------------------------------
echo
echo "=== Checking ComfyUI app update policy ==="
if [ "$COMFYUI_AUTO_UPDATE" = "1" ]; then
  echo "[RUN] Updating ComfyUI"
  run_as_mambauser "cd '${COMFYUI_APP_BASE}' && git pull --ff-only" || true
else
  echo "Skip update: COMFYUI_AUTO_UPDATE=${COMFYUI_AUTO_UPDATE}"
fi

# safe.directory
run_as_mambauser "git config --global --add safe.directory '${COMFYUI_APP_BASE}'" || true

# ----------------------------------------
# Ensure requested custom nodes exist in persistent custom_nodes
# ----------------------------------------
echo
echo "=== Clone / Update custom nodes ==="

CUSTOM_NODE_REPOS=(
  "https://github.com/city96/ComfyUI-GGUF.git"
  "https://github.com/DoctorDiffusion/ComfyUI-MediaMixer.git"
  "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
  "https://github.com/rgthree/rgthree-comfy.git"
  "https://github.com/jamesWalker55/comfyui-various.git"
  "https://github.com/Smirnov75/ComfyUI-mxToolkit.git"
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
  "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git"
  "https://github.com/kijai/ComfyUI-KJNodes.git"
  "https://github.com/WASasquatch/was-node-suite-comfyui.git"
)

for repo in "${CUSTOM_NODE_REPOS[@]}"; do
  clone_or_update_repo "$repo" "${COMFYUI_APP_BASE}/custom_nodes"
done

# keep permissions sane
chown -R "${MAMBA_USER:-mambauser}:${MAMBA_USER:-mambauser}" "${STORAGE_COMFYUI_DIR}" || true

# ----------------------------------------
# Install custom node dependencies (optional)
# ----------------------------------------
if [ "$COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS" = "1" ]; then
  install_custom_node_deps
else
  echo
  echo "=== Skip custom node dependency install: COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS=${COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS} ==="
fi

# ----------------------------------------
# Install Jupyter extension if bundled
# ----------------------------------------
install_jlab_extension_if_present

# ----------------------------------------
# Start supervisord (ComfyUI)
# ----------------------------------------
echo
echo "=== Starting supervisord ==="
/usr/bin/supervisord -c /etc/supervisord.conf

# log helpful info
echo
echo "=== Runtime info ==="
echo "COMFYUI_APP_BASE=${COMFYUI_APP_BASE}"
echo "COMFYUI_LISTEN_HOST=${COMFYUI_LISTEN_HOST}"
echo "COMFYUI_PORT=${COMFYUI_PORT}"
echo "COMFYUI_EXTRA_ARGS=${COMFYUI_EXTRA_ARGS}"
echo "HF_HOME=${HF_HOME}"
echo "Jupyter command: $*"

# ----------------------------------------
# Hand off to CMD
# ----------------------------------------
echo
echo "=== Launching main process ==="
exec "$@"

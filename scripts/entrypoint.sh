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

COMFYUI_AUTO_UPDATE="${COMFYUI_AUTO_UPDATE:-0}"
COMFYUI_CUSTOM_NODES_AUTO_UPDATE="${COMFYUI_CUSTOM_NODES_AUTO_UPDATE:-0}"

export PATH="${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}"
export HF_HOME

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

# ----------------------------------------
# Prepare persistent storage
# ----------------------------------------
echo
echo "=== Preparing persistent directories ==="

mkdir -p "${STORAGE_COMFYUI_DIR}/input" \
         "${STORAGE_COMFYUI_DIR}/output" \
         "${STORAGE_COMFYUI_DIR}/custom_nodes" \
         "${STORAGE_COMFYUI_DIR}/user" \
         "${JLAB_EXTENSIONS_DIR}" \
         "${HF_HOME}" \
         /workspace \
         /workspace/data \
         /workspace/notebooks

chown -R "${MAMBA_USER:-mambauser}:${MAMBA_USER:-mambauser}" "${STORAGE_BASE}" /workspace || true

# models はストレージに逃がさない
for d in input output custom_nodes user; do
  link_dir "${COMFYUI_APP_BASE}/${d}" "${STORAGE_COMFYUI_DIR}/${d}"
done

if [ -d /opt/app/jlab_extensions ]; then
  rsync -a /opt/app/jlab_extensions/ "${JLAB_EXTENSIONS_DIR}/" || true
fi

# ----------------------------------------
# Create notebooks-visible structure
# output is visible via /notebooks/ComfyUI/output
# ----------------------------------------
echo
echo "=== Creating notebooks visible structure ==="

ln -sfn /opt/app/ComfyUI /notebooks/ComfyUI
ln -sfn "${COMFYUI_APP_BASE}/input" /notebooks/input
ln -sfn "${COMFYUI_APP_BASE}/custom_nodes" /notebooks/custom_nodes

# /notebooks/output は作らない
rm -rf /notebooks/output 2>/dev/null || true

# ----------------------------------------
# Optional ComfyUI update
# ----------------------------------------
echo
echo "=== Checking ComfyUI app update policy ==="
if [ "$COMFYUI_AUTO_UPDATE" = "1" ]; then
  echo "[RUN] Updating ComfyUI"
  run_as_mambauser "cd '${COMFYUI_APP_BASE}' && git pull --ff-only" || true
else
  echo "Skip update: COMFYUI_AUTO_UPDATE=${COMFYUI_AUTO_UPDATE}"
fi

run_as_mambauser "git config --global --add safe.directory '${COMFYUI_APP_BASE}'" || true

# ----------------------------------------
# Ensure requested custom nodes exist
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

chown -R "${MAMBA_USER:-mambauser}:${MAMBA_USER:-mambauser}" "${STORAGE_COMFYUI_DIR}" || true

# ----------------------------------------
# Skip heavy startup tasks
# ----------------------------------------
echo
echo "=== Skip custom node dependency install at startup ==="
echo "=== Skip JupyterLab extension install at startup ==="

# ----------------------------------------
# Start supervisord
# ----------------------------------------
echo
echo "=== Starting supervisord ==="

if ! command -v supervisord >/dev/null 2>&1; then
  echo "ERROR: supervisord not found in PATH"
  echo "PATH=$PATH"
  exit 1
fi

supervisord -c /etc/supervisord.conf

echo
echo "=== Runtime info ==="
echo "COMFYUI_APP_BASE=${COMFYUI_APP_BASE}"
echo "HF_HOME=${HF_HOME}"
echo "Jupyter command: $*"

# ----------------------------------------
# Hand off to CMD
# ----------------------------------------
echo
echo "=== Launching main process ==="
exec "$@"

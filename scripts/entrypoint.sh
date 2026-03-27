#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== paperspace-custom: entrypoint start ==="

# ----------------------------------------
# Basic paths / env
# ----------------------------------------
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/conda}"
COMFYUI_APP_BASE="${COMFYUI_APP_BASE:-/opt/app/ComfyUI}"
NOTEBOOK_COMFYUI_DIR="${NOTEBOOK_COMFYUI_DIR:-/notebooks/ComfyUI}"
HF_HOME="${HF_HOME:-/opt/app/hf_home}"
COMFYUI_PORT="${COMFYUI_PORT:-8189}"
COMFYUI_LISTEN_HOST="${COMFYUI_LISTEN_HOST:-0.0.0.0}"
COMFYUI_EXTRA_ARGS="${COMFYUI_EXTRA_ARGS:---disable-auto-launch --preview-method none --force-fp16 --use-split-cross-attention}"
COMFYUI_AUTO_UPDATE="${COMFYUI_AUTO_UPDATE:-0}"
COMFYUI_CUSTOM_NODES_AUTO_UPDATE="${COMFYUI_CUSTOM_NODES_AUTO_UPDATE:-0}"
COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS="${COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS:-0}"

export PATH="${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}"
export HF_HOME
export HF_HUB_CACHE="${HF_HUB_CACHE:-/opt/app/hf_home/hub}"
export HF_ASSETS_CACHE="${HF_ASSETS_CACHE:-/opt/app/hf_home/assets}"
export HF_XET_CACHE="${HF_XET_CACHE:-/opt/app/hf_home/xet}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/opt/app/hf_home/transformers}"
export COMFYUI_PORT
export COMFYUI_LISTEN_HOST
export COMFYUI_EXTRA_ARGS

# ----------------------------------------
# Helper functions
# ----------------------------------------
run_as_mambauser() {
  su - "${MAMBA_USER:-mambauser}" -s /bin/bash -c "$*"
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
    if [ "${COMFYUI_CUSTOM_NODES_AUTO_UPDATE}" = "1" ]; then
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

ensure_models_symlink() {
  mkdir -p "${NOTEBOOK_COMFYUI_DIR}"
  if [ -L "${NOTEBOOK_COMFYUI_DIR}/models" ]; then
    return 0
  fi
  rm -rf "${NOTEBOOK_COMFYUI_DIR}/models"
  ln -s "${COMFYUI_APP_BASE}/models" "${NOTEBOOK_COMFYUI_DIR}/models"
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
      pip install . || true
    )
  done < <(find "${COMFYUI_APP_BASE}/custom_nodes" -maxdepth 2 -name pyproject.toml -print0)
}

start_comfyui_background() {
  echo
  echo "=== Starting ComfyUI background server ==="
  run_as_mambauser "cd '${COMFYUI_APP_BASE}' && python main.py --listen ${COMFYUI_LISTEN_HOST} --port ${COMFYUI_PORT} ${COMFYUI_EXTRA_ARGS}" &
}

# ----------------------------------------
# Prepare runtime dirs
# ----------------------------------------
mkdir -p \
  "${COMFYUI_APP_BASE}/models" \
  "${COMFYUI_APP_BASE}/input" \
  "${COMFYUI_APP_BASE}/output" \
  "${COMFYUI_APP_BASE}/temp" \
  "${COMFYUI_APP_BASE}/user" \
  "${HF_HOME}" \
  "${HF_HUB_CACHE}" \
  "${HF_ASSETS_CACHE}" \
  "${HF_XET_CACHE}" \
  "${TRANSFORMERS_CACHE}"

ensure_models_symlink

# ----------------------------------------
# Optional updates
# ----------------------------------------
if [ "${COMFYUI_AUTO_UPDATE}" = "1" ]; then
  echo
  echo "=== Updating ComfyUI ==="
  run_as_mambauser "cd '${COMFYUI_APP_BASE}' && git pull --ff-only" || true
fi

if [ "${COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS}" = "1" ]; then
  install_custom_node_deps || true
fi

# ----------------------------------------
# Start ComfyUI in background
# ----------------------------------------
start_comfyui_background

echo
echo "=== Launching main process ==="
exec "$@"

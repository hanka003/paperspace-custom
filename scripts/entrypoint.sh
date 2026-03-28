#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== paperspace-custom: entrypoint start ==="

# ----------------------------------------
# Basic paths / env
# ----------------------------------------
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/conda}"

# テンプレート元（イメージ内）
COMFYUI_TEMPLATE_BASE="${COMFYUI_TEMPLATE_BASE:-/opt/app/ComfyUI}"

# 実行実体（notebooks 側）
COMFYUI_APP_BASE="${COMFYUI_APP_BASE:-/notebooks/ComfyUI}"

# 永続ストレージ
STORAGE_BASE="${STORAGE_BASE:-/storage/sd-suite}"
STORAGE_COMFYUI_DIR="${STORAGE_COMFYUI_DIR:-${STORAGE_BASE}/comfyui}"
JLAB_EXTENSIONS_DIR="${JLAB_EXTENSIONS_DIR:-${STORAGE_BASE}/jlab_extensions}"
HF_HOME="${HF_HOME:-${STORAGE_BASE}/hf_cache}"

# models は opt 側に固定
COMFYUI_MODELS_BASE="${COMFYUI_MODELS_BASE:-/opt/app/ComfyUI/models}"

COMFYUI_PORT="${COMFYUI_PORT:-8189}"
COMFYUI_LISTEN_HOST="${COMFYUI_LISTEN_HOST:-0.0.0.0}"
COMFYUI_EXTRA_ARGS="${COMFYUI_EXTRA_ARGS:---disable-auto-launch}"
COMFYUI_AUTO_UPDATE="${COMFYUI_AUTO_UPDATE:-0}"
COMFYUI_CUSTOM_NODES_AUTO_UPDATE="${COMFYUI_CUSTOM_NODES_AUTO_UPDATE:-0}"

export PATH="${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}"
export HF_HOME
export COMFYUI_APP_BASE
export COMFYUI_MODELS_BASE
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
    rm -f "$src"
  elif [ -d "$src" ] && [ ! -L "$src" ]; then
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
# Prepare persistent directories
# ----------------------------------------
echo
echo "=== Preparing persistent directories ==="

mkdir -p \
  "${STORAGE_COMFYUI_DIR}/input" \
  "${STORAGE_COMFYUI_DIR}/output" \
  "${STORAGE_COMFYUI_DIR}/custom_nodes" \
  "${JLAB_EXTENSIONS_DIR}" \
  "${HF_HOME}" \
  /workspace \
  /workspace/data \
  /workspace/notebooks \
  /notebooks \
  "${COMFYUI_MODELS_BASE}"

# models 以下を全部 opt 側に用意
mkdir -p \
  "${COMFYUI_MODELS_BASE}/checkpoints" \
  "${COMFYUI_MODELS_BASE}/clip" \
  "${COMFYUI_MODELS_BASE}/clip_vision" \
  "${COMFYUI_MODELS_BASE}/configs" \
  "${COMFYUI_MODELS_BASE}/controlnet" \
  "${COMFYUI_MODELS_BASE}/diffusers" \
  "${COMFYUI_MODELS_BASE}/diffusion_models" \
  "${COMFYUI_MODELS_BASE}/embeddings" \
  "${COMFYUI_MODELS_BASE}/gligen" \
  "${COMFYUI_MODELS_BASE}/hypernetworks" \
  "${COMFYUI_MODELS_BASE}/ipadapter" \
  "${COMFYUI_MODELS_BASE}/loras" \
  "${COMFYUI_MODELS_BASE}/photomaker" \
  "${COMFYUI_MODELS_BASE}/style_models" \
  "${COMFYUI_MODELS_BASE}/unet" \
  "${COMFYUI_MODELS_BASE}/upscale_models" \
  "${COMFYUI_MODELS_BASE}/vae" \
  "${COMFYUI_MODELS_BASE}/vae_approx"

chown -R "${MAMBA_USER:-mambauser}:${MAMBA_USER:-mambauser}" \
  "${STORAGE_BASE}" /workspace /notebooks "${COMFYUI_MODELS_BASE}" || true

# ----------------------------------------
# Build real /notebooks/ComfyUI (NOT symlink)
# ----------------------------------------
echo
echo "=== Preparing real runtime tree at /notebooks/ComfyUI ==="

# 既存の /notebooks/ComfyUI が symlink なら消す
if [ -L "${COMFYUI_APP_BASE}" ]; then
  rm -f "${COMFYUI_APP_BASE}"
fi

mkdir -p "${COMFYUI_APP_BASE}"

# 初回だけ /opt/app/ComfyUI から本体をコピー
if [ ! -f "${COMFYUI_APP_BASE}/main.py" ]; then
  echo "Initial sync: ${COMFYUI_TEMPLATE_BASE} -> ${COMFYUI_APP_BASE}"
  rsync -a \
    --exclude models \
    --exclude input \
    --exclude output \
    --exclude custom_nodes \
    --exclude user \
    "${COMFYUI_TEMPLATE_BASE}/" "${COMFYUI_APP_BASE}/"
fi

# notebooks 側に workflow 保存先を確保
mkdir -p \
  "${COMFYUI_APP_BASE}/user/default/workflows" \
  "${COMFYUI_APP_BASE}/user/default"

# ----------------------------------------
# Link runtime directories
# ----------------------------------------
echo
echo "=== Linking runtime directories ==="

# notebooks 実体側から見せる
link_dir "${COMFYUI_APP_BASE}/input"        "${STORAGE_COMFYUI_DIR}/input"
link_dir "${COMFYUI_APP_BASE}/output"       "${STORAGE_COMFYUI_DIR}/output"
link_dir "${COMFYUI_APP_BASE}/custom_nodes" "${STORAGE_COMFYUI_DIR}/custom_nodes"

# models 以下は全部 /opt/app/ComfyUI/models に保存
link_dir "${COMFYUI_APP_BASE}/models"       "${COMFYUI_MODELS_BASE}"

# user は notebooks 側に残す（workflow を notebooks に保存したいので）
mkdir -p "${COMFYUI_APP_BASE}/user/default/workflows"

# 補助リンク
ln -sfn "${COMFYUI_APP_BASE}/input" /notebooks/input
ln -sfn "${COMFYUI_APP_BASE}/custom_nodes" /notebooks/custom_nodes
rm -rf /notebooks/output 2>/dev/null || true

if [ -d /opt/app/jlab_extensions ]; then
  rsync -a /opt/app/jlab_extensions/ "${JLAB_EXTENSIONS_DIR}/" || true
fi

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
  "https://github.com/kijai/ComfyUI-KJNodes.git"
)

for repo in "${CUSTOM_NODE_REPOS[@]}"; do
  clone_or_update_repo "$repo" "${COMFYUI_APP_BASE}/custom_nodes"
done

chown -R "${MAMBA_USER:-mambauser}:${MAMBA_USER:-mambauser}" \
  "${STORAGE_COMFYUI_DIR}" "${COMFYUI_APP_BASE}" "${COMFYUI_MODELS_BASE}" || true

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
echo "COMFYUI_TEMPLATE_BASE=${COMFYUI_TEMPLATE_BASE}"
echo "COMFYUI_APP_BASE=${COMFYUI_APP_BASE}"
echo "COMFYUI_MODELS_BASE=${COMFYUI_MODELS_BASE}"
echo "HF_HOME=${HF_HOME}"
echo "Workflow dir=${COMFYUI_APP_BASE}/user/default/workflows"
echo "Checkpoints dir=${COMFYUI_MODELS_BASE}/checkpoints"
echo "Jupyter command: $*"

# ----------------------------------------
# Hand off to CMD
# ----------------------------------------
echo
echo "=== Launching main process ==="
exec "$@"

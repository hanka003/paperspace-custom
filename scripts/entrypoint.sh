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

# 互換用 workspace 側
COMFYUI_WORKSPACE_BASE="${COMFYUI_WORKSPACE_BASE:-/workspace/ComfyUI}"

# 永続ストレージ
STORAGE_BASE="${STORAGE_BASE:-/storage/sd-suite}"
STORAGE_COMFYUI_DIR="${STORAGE_COMFYUI_DIR:-${STORAGE_BASE}/comfyui}"
JLAB_EXTENSIONS_DIR="${JLAB_EXTENSIONS_DIR:-${STORAGE_BASE}/jlab_extensions}"
HF_HOME="${HF_HOME:-${STORAGE_BASE}/hf_cache}"

# models は必ず opt/app 側に固定
COMFYUI_MODELS_BASE="${COMFYUI_MODELS_BASE:-/opt/app/ComfyUI/models}"

# custom_nodes配下の重いモデル置き場
CUSTOM_NODE_MODELS_BASE="${CUSTOM_NODE_MODELS_BASE:-/opt/app/custom_node_models}"

# 後から追加しやすい設定ファイル
CUSTOM_NODE_HEAVY_CONFIG="${CUSTOM_NODE_HEAVY_CONFIG:-/storage/sd-suite/config/custom_node_heavy_dirs.conf}"

# 環境変数でも追加可能
# 1行1件、形式:
#   repo_name:relative/path
# 例:
#   ComfyUI-Frame-Interpolation:models
#   SomeNode:weights
CUSTOM_NODE_HEAVY_DIRS="${CUSTOM_NODE_HEAVY_DIRS:-}"

COMFYUI_PORT="${COMFYUI_PORT:-8189}"
COMFYUI_LISTEN_HOST="${COMFYUI_LISTEN_HOST:-0.0.0.0}"
COMFYUI_EXTRA_ARGS="${COMFYUI_EXTRA_ARGS:---disable-auto-launch}"
COMFYUI_AUTO_UPDATE="${COMFYUI_AUTO_UPDATE:-0}"
COMFYUI_CUSTOM_NODES_AUTO_UPDATE="${COMFYUI_CUSTOM_NODES_AUTO_UPDATE:-0}"

export PATH="${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}"
export HF_HOME
export COMFYUI_APP_BASE
export COMFYUI_TEMPLATE_BASE
export COMFYUI_WORKSPACE_BASE
export COMFYUI_MODELS_BASE
export CUSTOM_NODE_MODELS_BASE
export CUSTOM_NODE_HEAVY_CONFIG
export CUSTOM_NODE_HEAVY_DIRS
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

trim_spaces() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

link_custom_node_heavy_dir() {
    local node_name="$1"
    local rel_path="$2"

    node_name="$(trim_spaces "$node_name")"
    rel_path="$(trim_spaces "$rel_path")"

    [ -z "$node_name" ] && return 0
    [ -z "$rel_path" ] && return 0

    local src="${COMFYUI_APP_BASE}/custom_nodes/${node_name}/${rel_path}"
    local dst="${CUSTOM_NODE_MODELS_BASE}/${node_name}/${rel_path}"

    echo "Link heavy custom-node dir: ${src} -> ${dst}"
    mkdir -p "$(dirname "$dst")"
    link_dir "$src" "$dst"

    # template/workspace側も同じ場所を見せる
    local template_src="${COMFYUI_TEMPLATE_BASE}/custom_nodes/${node_name}/${rel_path}"
    local workspace_src="${COMFYUI_WORKSPACE_BASE}/custom_nodes/${node_name}/${rel_path}"
    link_dir "$template_src" "$dst"
    link_dir "$workspace_src" "$dst"
}

apply_heavy_dir_specs_from_text() {
    local source_name="$1"
    local payload="$2"

    [ -z "${payload}" ] && return 0

    echo
    echo "=== Applying heavy-dir specs from ${source_name} ==="

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        local line
        line="$(trim_spaces "$raw_line")"

        # 空行・コメント行は無視
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac

        # "repo:path"
        if [[ "$line" == *:* ]]; then
            local node_name="${line%%:*}"
            local rel_path="${line#*:}"
            link_custom_node_heavy_dir "$node_name" "$rel_path"
        else
            echo "Skip invalid heavy-dir spec (${source_name}): $line"
        fi
    done <<< "$payload"
}

setup_custom_node_heavy_dirs() {
    echo
    echo "=== Linking heavy custom-node model directories to /opt ==="

    # 初期値。後で config や環境変数で増やせる。
    local builtins
    builtins=$'ComfyUI-Frame-Interpolation:models'

    apply_heavy_dir_specs_from_text "built-in defaults" "$builtins"

    if [ -f "$CUSTOM_NODE_HEAVY_CONFIG" ]; then
        apply_heavy_dir_specs_from_text "config file: $CUSTOM_NODE_HEAVY_CONFIG" "$(cat "$CUSTOM_NODE_HEAVY_CONFIG")"
    else
        echo "No custom heavy-dir config file: $CUSTOM_NODE_HEAVY_CONFIG"
    fi

    if [ -n "$CUSTOM_NODE_HEAVY_DIRS" ]; then
        apply_heavy_dir_specs_from_text "CUSTOM_NODE_HEAVY_DIRS env" "$CUSTOM_NODE_HEAVY_DIRS"
    else
        echo "No CUSTOM_NODE_HEAVY_DIRS env provided"
    fi
}

ensure_heavy_dir_example_config() {
    mkdir -p "$(dirname "$CUSTOM_NODE_HEAVY_CONFIG")"
    if [ ! -f "$CUSTOM_NODE_HEAVY_CONFIG" ]; then
        cat > "$CUSTOM_NODE_HEAVY_CONFIG" <<'EOF'
# 1行1件、形式:
# repo_name:relative/path
#
# 例:
# ComfyUI-Frame-Interpolation:models
# SomeNode:models
# SomeNode:weights
# SomeNode:checkpoints
# SomeNode:onnx
# SomeNode:ckpts
EOF
        chown "${MAMBA_USER:-mambauser}:${MAMBA_USER:-mambauser}" "$CUSTOM_NODE_HEAVY_CONFIG" || true
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
  "${STORAGE_BASE}/config" \
  "${JLAB_EXTENSIONS_DIR}" \
  "${HF_HOME}" \
  /workspace \
  /workspace/data \
  /workspace/notebooks \
  /notebooks \
  "${COMFYUI_MODELS_BASE}" \
  "${CUSTOM_NODE_MODELS_BASE}"

# models 以下は全部 opt/app 側に用意
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
  "${STORAGE_BASE}" /workspace /notebooks "${COMFYUI_MODELS_BASE}" "${CUSTOM_NODE_MODELS_BASE}" || true

ensure_heavy_dir_example_config

# ----------------------------------------
# Build real /notebooks/ComfyUI (NOT symlink)
# ----------------------------------------
echo
echo "=== Preparing real runtime tree at /notebooks/ComfyUI ==="
if [ -L "${COMFYUI_APP_BASE}" ]; then
    rm -f "${COMFYUI_APP_BASE}"
fi
mkdir -p "${COMFYUI_APP_BASE}"

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

mkdir -p \
  "${COMFYUI_APP_BASE}/user/default/workflows" \
  "${COMFYUI_APP_BASE}/user/default"

# ----------------------------------------
# Prepare workspace compatibility tree
# ----------------------------------------
echo
echo "=== Preparing workspace compatibility tree ==="
mkdir -p "${COMFYUI_WORKSPACE_BASE}"

if [ ! -f "${COMFYUI_WORKSPACE_BASE}/main.py" ]; then
    echo "Initial sync: ${COMFYUI_APP_BASE} -> ${COMFYUI_WORKSPACE_BASE}"
    rsync -a \
      --exclude models \
      --exclude input \
      --exclude output \
      --exclude custom_nodes \
      --exclude user \
      "${COMFYUI_APP_BASE}/" "${COMFYUI_WORKSPACE_BASE}/"
fi

mkdir -p "${COMFYUI_WORKSPACE_BASE}/user/default/workflows"

# ----------------------------------------
# Link runtime directories
# ----------------------------------------
echo
echo "=== Linking runtime directories ==="

# notebooks 側
link_dir "${COMFYUI_APP_BASE}/input" "${STORAGE_COMFYUI_DIR}/input"
link_dir "${COMFYUI_APP_BASE}/output" "${STORAGE_COMFYUI_DIR}/output"
link_dir "${COMFYUI_APP_BASE}/custom_nodes" "${STORAGE_COMFYUI_DIR}/custom_nodes"
link_dir "${COMFYUI_APP_BASE}/models" "${COMFYUI_MODELS_BASE}"

# opt/app 側
link_dir "${COMFYUI_TEMPLATE_BASE}/input" "${STORAGE_COMFYUI_DIR}/input"
link_dir "${COMFYUI_TEMPLATE_BASE}/output" "${STORAGE_COMFYUI_DIR}/output"
link_dir "${COMFYUI_TEMPLATE_BASE}/custom_nodes" "${STORAGE_COMFYUI_DIR}/custom_nodes"
# models は /opt/app/ComfyUI/models そのものなので触らない

# workspace 側
link_dir "${COMFYUI_WORKSPACE_BASE}/input" "${STORAGE_COMFYUI_DIR}/input"
link_dir "${COMFYUI_WORKSPACE_BASE}/output" "${STORAGE_COMFYUI_DIR}/output"
link_dir "${COMFYUI_WORKSPACE_BASE}/custom_nodes" "${STORAGE_COMFYUI_DIR}/custom_nodes"
link_dir "${COMFYUI_WORKSPACE_BASE}/models" "${COMFYUI_MODELS_BASE}"

# user は notebooks / workspace 側に残す
mkdir -p "${COMFYUI_APP_BASE}/user/default/workflows"
mkdir -p "${COMFYUI_WORKSPACE_BASE}/user/default/workflows"

# 補助リンク
ln -sfn "${COMFYUI_APP_BASE}/input" /notebooks/input
ln -sfn "${COMFYUI_APP_BASE}/custom_nodes" /notebooks/custom_nodes
ln -sfn "${COMFYUI_APP_BASE}/output" /notebooks/output

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
run_as_mambauser "git config --global --add safe.directory '${COMFYUI_WORKSPACE_BASE}'" || true
run_as_mambauser "git config --global --add safe.directory '${COMFYUI_TEMPLATE_BASE}'" || true

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

# custom_nodes配下の重いモデルディレクトリを /opt 側へ退避
setup_custom_node_heavy_dirs

chown -R "${MAMBA_USER:-mambauser}:${MAMBA_USER:-mambauser}" \
  "${STORAGE_COMFYUI_DIR}" \
  "${COMFYUI_APP_BASE}" \
  "${COMFYUI_WORKSPACE_BASE}" \
  "${COMFYUI_TEMPLATE_BASE}" \
  "${COMFYUI_MODELS_BASE}" \
  "${CUSTOM_NODE_MODELS_BASE}" || true

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
echo "COMFYUI_WORKSPACE_BASE=${COMFYUI_WORKSPACE_BASE}"
echo "COMFYUI_MODELS_BASE=${COMFYUI_MODELS_BASE}"
echo "CUSTOM_NODE_MODELS_BASE=${CUSTOM_NODE_MODELS_BASE}"
echo "CUSTOM_NODE_HEAVY_CONFIG=${CUSTOM_NODE_HEAVY_CONFIG}"
echo "HF_HOME=${HF_HOME}"
echo "Workflow dir=${COMFYUI_APP_BASE}/user/default/workflows"
echo "Checkpoints dir=${COMFYUI_MODELS_BASE}/checkpoints"
echo "Models realpath=$(readlink -f "${COMFYUI_MODELS_BASE}" || true)"
echo "Custom-node model store=$(readlink -f "${CUSTOM_NODE_MODELS_BASE}" || true)"
echo "Output (notebooks)=$(readlink -f "${COMFYUI_APP_BASE}/output" || true)"
echo "Output (opt)=$(readlink -f "${COMFYUI_TEMPLATE_BASE}/output" || true)"
echo "Output (workspace)=$(readlink -f "${COMFYUI_WORKSPACE_BASE}/output" || true)"
echo "Jupyter command: $*"

# ----------------------------------------
# Hand off to CMD
# ----------------------------------------
echo
echo "=== Launching main process ==="
exec "$@"

#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Install custom node dependencies: start ==="

export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-/opt/conda}"
export PATH="${MAMBA_ROOT_PREFIX}/envs/pyenv/bin:${MAMBA_ROOT_PREFIX}/bin:${PATH}"

CUSTOM_NODES_DIR="${CUSTOM_NODES_DIR:-/opt/app/ComfyUI/custom_nodes}"

if [ ! -d "$CUSTOM_NODES_DIR" ]; then
    echo "Custom nodes directory not found: $CUSTOM_NODES_DIR"
    exit 1
fi

echo "Using CUSTOM_NODES_DIR=$CUSTOM_NODES_DIR"
echo
echo "=== Installing requirements.txt files ==="

find "$CUSTOM_NODES_DIR" -maxdepth 2 -name requirements.txt -print0 | \
  xargs -0 -r -I {} sh -c 'echo "[requirements] {}"; pip install -r "{}"' || true

echo
echo "=== Installing pyproject.toml packages ==="

find "$CUSTOM_NODES_DIR" -maxdepth 2 -name pyproject.toml -print0 | \
  xargs -0 -r -I {} sh -c 'd="$(dirname "{}")"; echo "[pyproject] $d"; cd "$d" && pip install .' || true

echo
echo "=== Install custom node dependencies: done ==="
echo "Run this after Jupyter starts:"
echo " /usr/local/bin/install_custom_node_deps.sh"

# paperspace-custom patched

この修正版では、custom node 配下に置かれる重いモデルを `/opt/app/custom_node_models` に逃がせます。

## 追加方法

### 方法1: 設定ファイル
起動後に以下へ追記します。

`/storage/sd-suite/config/custom_node_heavy_dirs.conf`

形式:
`repo_name:relative/path`

例:
```text
ComfyUI-Frame-Interpolation:models
SomeNode:weights
SomeNode:checkpoints
```

### 方法2: 環境変数
```bash
CUSTOM_NODE_HEAVY_DIRS=$'ComfyUI-Frame-Interpolation:models\nSomeNode:weights'
```

## 実際の保存先
たとえば `SomeNode:weights` を追加すると、実体は次になります。

`/opt/app/custom_node_models/SomeNode/weights`

元の `custom_nodes/SomeNode/weights` には symlink が張られます。

#!/usr/bin/env bash
# 把 落地页 + 元数据 + 图片 同步到你的服务器（需 ssh 免密）。用法：
#   IMAGE_BASE=https://niulai.xyz/img/ EXTERNAL=https://niulai.xyz VAULT=0x... HOST=user@1.2.3.4 ./server/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HOST:?HOST=user@server 必填}"; : "${IMAGE_BASE:?IMAGE_BASE=https://域名/img/ 必填}"
EXTERNAL=${EXTERNAL:-https://niulai.example}; VAULT=${VAULT:-0x0000000000000000000000000000000000000000}; DEST=${DEST:-/var/www/niulai}
.venv/bin/python pipeline/export_metadata.py --image-base "$IMAGE_BASE" --external "$EXTERNAL" --vault "$VAULT"
ssh "$HOST" "mkdir -p $DEST/meta $DEST/img"
rsync -az --delete out/chain/ "$HOST:$DEST/meta/"
rsync -az out/png/ "$HOST:$DEST/img/"
rsync -az web/ "$HOST:$DEST/"
echo "✔ 已同步：$EXTERNAL/meta/1.json  $IMAGE_BASE/0001.png  合约 baseURI 设为 $EXTERNAL/meta/"

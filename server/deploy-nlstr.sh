#!/usr/bin/env bash
# 部署永动机页面 → https://niulai.sbs/nlstr/
#   ./server/deploy-nlstr.sh                       # 只传页面
#   ./server/deploy-nlstr.sh --data                # 顺带把本地 orders.json / candles.json 也传上去
# 页面里的资源引用是绝对路径（/assets/…），所以放在 /nlstr/ 子目录下也能正常加载。
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${HOST:-root@2.24.118.196}; DEST=${DEST:-/var/www/niulai}
ssh "$HOST" "mkdir -p $DEST/nlstr"
rsync -az web/assets/lwc.js        "$HOST:$DEST/assets/lwc.js"
rsync -az web/machine.html         "$HOST:$DEST/nlstr/index.html"
rsync -az web/index.html           "$HOST:$DEST/index.html"
if [ "${1:-}" = "--data" ]; then
  for f in orders.json candles.json; do
    [ -f "web/$f" ] && rsync -az "web/$f" "$HOST:$DEST/nlstr/$f" && echo "  + $f"
  done
fi
code=$(curl -sS -o /dev/null -w '%{http_code}' -L https://niulai.sbs/nlstr/)
echo "✔ https://niulai.sbs/nlstr/  → HTTP $code"

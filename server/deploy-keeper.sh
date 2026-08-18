#!/usr/bin/env bash
# 把永动机的 keeper + K线索引装成服务器上的 systemd 服务。
#   ./server/deploy-keeper.sh            # 装/更新代码与 unit（不启动）
#   ./server/deploy-keeper.sh --restart  # 顺便重启（.env 填好之后用）
# 两个服务都装成 disabled，因为合约还没部署；填好 .env 再 enable。
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${HOST:-root@2.24.118.196}; APP=${APP:-/opt/niulai/strategy}; WWW=${WWW:-/var/www/niulai/nlstr}

ssh "$HOST" "mkdir -p $APP/scripts $WWW"
rsync -az strategy/scripts/keeper.mjs strategy/scripts/candles.mjs strategy/package.json "$HOST:$APP/scripts/" 2>/dev/null || true
rsync -az strategy/scripts/keeper.mjs strategy/scripts/candles.mjs "$HOST:$APP/scripts/"
rsync -az strategy/package.json "$HOST:$APP/package.json"

ssh "$HOST" "bash -s" <<EOF
set -euo pipefail
cd $APP
[ -d node_modules/ethers ] || npm install --silent --no-audit --no-fund ethers@6.17.0

# .env 只在第一次创建，之后不覆盖（里面有私钥）
if [ ! -f $APP/.env ]; then
  cat > $APP/.env <<'ENV'
RPC_URL=https://lb.drpc.live/bsc/AsVs23QoLEOwisC7Py3FTOo-9Orrf6UR8a6vijtBrJVX
KEEPER_PK=
# 下面三个从 Deploy 脚本的输出里抄
TREASURY=
NLSTR=
HOOK=
# keeper
OPEN_ORDERS=3
POLL_SEC=60
ORDER_TTL_H=24
ORDERS_OUT=/var/www/niulai/nlstr/orders.json
# K线（POOL_ID 不填，脚本会用 NLSTR+HOOK 自己算）
CANDLES_OUT=/var/www/niulai/nlstr/candles.json
INTERVAL=60
LOG_STEP=20000
ENV
  chmod 600 $APP/.env
  echo "已创建 $APP/.env（KEEPER_PK 和三个地址还是空的）"
fi

for svc in keeper candles; do
  cat > /etc/systemd/system/nlstr-\$svc.service <<UNIT
[Unit]
Description=NLSTR \$svc
After=network-online.target
[Service]
WorkingDirectory=$APP
EnvironmentFile=$APP/.env
ExecStart=/usr/bin/node scripts/\$svc.mjs
Restart=always
RestartSec=20
[Install]
WantedBy=multi-user.target
UNIT
done
systemctl daemon-reload
echo "unit 已就位：nlstr-keeper / nlstr-candles"
EOF

if [ "${1:-}" = "--restart" ]; then
  # 地址没填就启动 = 每 20 秒崩一次刷日志，不如直接拦住
  MISSING=$(ssh "$HOST" "grep -E '^(KEEPER_PK|TREASURY|NLSTR|HOOK)=\$' $APP/.env | cut -d= -f1 | tr '\n' ' '")
  if [ -n "$MISSING" ]; then
    echo "✗ $APP/.env 里这些还是空的：$MISSING"
    echo "  TREASURY/NLSTR/HOOK 要等合约部署完才有，填好再来。没启动任何服务。"
    exit 1
  fi
  ssh "$HOST" "systemctl enable --now nlstr-keeper nlstr-candles && sleep 5 && systemctl is-active nlstr-keeper nlstr-candles"
else
  echo
  echo "代码和 unit 装好了，但**没有启动**——合约还没部署，启动只会刷错误日志。"
  echo "开盘后："
  echo "  ssh $HOST 'nano $APP/.env'        # 填 KEEPER_PK / TREASURY / NLSTR / HOOK"
  echo "  ./server/deploy-keeper.sh --restart"
fi

#!/usr/bin/env bash
# 让 OKX NFT 市场刷新新铸造 token 的元数据（OKX 只在有人打开某个 token 页面/点“更新元数据”时才索引它）。
# 每次运行：读链上 totalSupply，把上次之后新增的 tokenId 逐个 POST 到 OKX 的刷新接口。cron 每 10 分钟跑一次即可。
#   */10 * * * * /opt/niulai/okx-refresh.sh >> /var/log/okx-refresh.log 2>&1
set -euo pipefail
NFT=${NFT:-0x5fd0d8fecf408f61080cea470249026d3e02fb3d}
RPC=${RPC:-https://lb.drpc.live/bsc/AsVs23QoLEOwisC7Py3FTOo-9Orrf6UR8a6vijtBrJVX}
STATE=${STATE:-/opt/niulai/okx-refresh.last}
last=$(cat "$STATE" 2>/dev/null || echo 0)
hex=$(curl -s -m 15 "$RPC" -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$NFT\",\"data\":\"0x18160ddd\"},\"latest\"]}" | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')
[ -n "$hex" ] || { echo "$(date -Is) rpc 失败"; exit 1; }
supply=$((16#$hex))
[ "$supply" -gt "$last" ] || { echo "$(date -Is) 无新增（supply=$supply）"; exit 0; }
ok=0
for id in $(seq $((last + 1)) "$supply"); do
  res=$(curl -s -m 15 -X POST "https://web3.okx.com/priapi/v1/nft/refresh?t=$(date +%s000)" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' -H 'App-Type: web' -H 'Platform: web' -H 'X-Locale: zh_CN' \
    -H 'User-Agent: Mozilla/5.0' -H 'Origin: https://web3.okx.com' -H "Referer: https://web3.okx.com/zh-hans/nft/asset/bsc/$NFT/$id" \
    --data "{\"contractAddress\":\"$NFT\",\"tokenId\":\"$id\",\"looker\":\"\",\"chain\":56}" || true)
  if echo "$res" | grep -q '"code":0'; then ok=$((ok + 1)); echo "$id" > "$STATE"; else echo "$(date -Is) #$id 失败: ${res:0:120}"; break; fi
  sleep 0.5
done
echo "$(date -Is) supply=$supply 刷新 $ok 个（$((last + 1))..$(cat "$STATE")）"

#!/usr/bin/env bash
# keeper 存活哨兵：日志静默超过阈值就重启并记账。
# 今天 keeper 卡在一个没有超时的 .wait() 上静默了 5 分钟，systemd 显示 active，
# 全靠人肉发现。cron 每 2 分钟跑一次。
set -uo pipefail
SVC=${SVC:-nlstr-keeper}
MAX_SILENT=${MAX_SILENT:-300}          # 秒
LOG=/var/log/nlstr-watchdog.log
now=$(date +%s)
last=$(journalctl -u "$SVC" -n 1 --no-pager -o short-unix 2>/dev/null | awk '{print int($1)}')
[ -z "${last:-}" ] && { echo "$(date -Is) 读不到 $SVC 日志" >> $LOG; exit 0; }
silent=$(( now - last ))
if ! systemctl is-active --quiet "$SVC"; then
  echo "$(date -Is) $SVC 不在运行，拉起" >> $LOG
  systemctl restart "$SVC"; exit 0
fi
if [ "$silent" -gt "$MAX_SILENT" ]; then
  echo "$(date -Is) $SVC 静默 ${silent}s（>${MAX_SILENT}s），重启" >> $LOG
  journalctl -u "$SVC" -n 5 --no-pager -o cat >> $LOG
  systemctl restart "$SVC"
fi

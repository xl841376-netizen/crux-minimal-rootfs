#!/bin/sh
# x50-online.sh —— X50 上线服务：等 QMI 起来后把它从 shutting-down 拨到 online
# 依据：2026-10-16 实测 模组 AMSS 起来后默认处于 'shutting-down'，不拨 online 它会走关机流程（dump EFS→复位）
# 只发一条 QMI(DMS_SET_OPERATING_MODE)，不碰 MHI WWAN 通道，不挂 diag
LOG=/var/log/x50-online.log
exec >>$LOG 2>&1
echo "=== x50-online start $(date) ==="
i=0
while [ $i -lt 120 ]; do
  i=$((i+1))
  M=$(timeout 15 qmicli -d qrtr://0 --dms-get-operating-mode 2>/dev/null | grep -o "Mode: *'[a-z-]*'" | head -1)
  case "$M" in
    *online*)
      echo "[$(date +%H:%M:%S)] mode=$M -> already online"; break ;;
    *shutting-down*|*offline*|*low-power*|*persistent-low-power*)
      echo "[$(date +%H:%M:%S)] mode=$M -> set online"
      timeout 20 qmicli -d qrtr://0 --dms-set-operating-mode=online 2>&1 | head -2
      sleep 5
      echo "[$(date +%H:%M:%S)] now: $(timeout 15 qmicli -d qrtr://0 --dms-get-operating-mode 2>/dev/null | grep -o "Mode: *'[a-z-]*'" | head -1)"
      ;;
    *)
      echo "[$(date +%H:%M:%S)] no QMI yet ($M)"; sleep 5 ;;
  esac
done
echo "=== x50-online done $(date) ==="
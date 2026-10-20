#!/bin/sh
# 每 15 秒把 dmesg 尾部快照写盘，仅保留最近两份，用于硬挂/重启后回溯死亡现场
OUT=/var/log/dmesg-snap.txt
i=0
while :; do
    {
        echo "=== SNAP $(date '+%F %T') uptime=$(cut -d. -f1 /proc/uptime)s"
        dmesg | tail -n 1200
    } > ${OUT}.tmp 2>/dev/null || true
    sync ${OUT}.tmp 2>/dev/null || true
    mv -f ${OUT}.tmp "$OUT" 2>/dev/null || true
    i=$((i+1))
    sleep 15
done

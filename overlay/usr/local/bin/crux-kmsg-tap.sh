#!/bin/sh
# crux-kmsg-tap: 持续把内核日志落盘，用于抓“突发死/复位”前的现场
# /var/log/crux-kmsg.log 超过 4MB 时保留末尾 512KB 后截断
LOG=/var/log/crux-kmsg.log
MAX=4194304
while :; do
    timeout 15 cat /dev/kmsg >> "$LOG" 2>/dev/null
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$MAX" ]; then
        tail -c 524288 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
    sync
    sleep 1
done
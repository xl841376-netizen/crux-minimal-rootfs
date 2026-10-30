#!/bin/sh
# crux-kmsg-tap: 持续把内核日志落盘，用于抓"突发死/复位"前的现场
#
# 2026-10-30 改：上限放大、清理时保留一半（原先是 4MB→只留 512KB，丢太多）
#   - 追加写入，不做任何"滚动重写"
#   - 只有超过 MAX 才清理：保留最后 KEEP 字节（约占一半），并且清理前先留一份归档
#   - 归档 kmsg.log.1 保留一份（再大就覆盖），磁盘有 52G 可用，代价很小
LOG=/var/log/crux-kmsg.log
ARCHIVE=/var/log/crux-kmsg.log.1
MAX=33554432        # 32 MB
KEEP=16777216       # 清理时保留 16 MB

while :; do
    timeout 15 cat /dev/kmsg >> "$LOG" 2>/dev/null

    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$MAX" ]; then
        # 先归档（只留一份，覆盖上一份归档）
        cp -f "$LOG" "$ARCHIVE" 2>/dev/null
        # 再从归档尾部取 KEEP 字节重建（这不是"丢内容"：完整内容已在归档里）
        tail -c "$KEEP" "$ARCHIVE" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
        logger -t crux-kmsg-tap "kmsg.log 超过 ${MAX}B，归档到 $(basename "$ARCHIVE") 并保留尾部 ${KEEP}B"
    fi

    sync
    sleep 1
done
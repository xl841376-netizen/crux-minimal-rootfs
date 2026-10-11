#!/bin/sh
# crux fastrpc 守护（重写版 2026-09-14）
# 保守策略：只在 fastrpc 未加载时 modprobe；失败仅记日志，不动内核/dtb/固件。
LOG=/var/log/crux-fastrpc-guard.log
say(){ echo "$(date '+%F %T') $*" >> $LOG; }
say "guard run (rewritten)"
if lsmod | grep -q '^fastrpc'; then
  say "fastrpc already loaded"
  exit 0
fi
say "fastrpc not loaded, modprobe"
if modprobe fastrpc 2>>$LOG; then say "modprobe ok"; else say "modprobe failed"; fi

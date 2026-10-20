#!/bin/bash
# [crux] UFS 稳定性加固（开机自愈，可重复执行，幂等）
#   目的：避免 UFS 因低功耗路径（自动 hibern8 / 时钟门控）与 LUN runtime autosuspend
#         导致的“链路死(-110)”与“关机静默跳过 SYNCHRONIZE CACHE”。
#   全部是标准 sysfs 开关，无副作用；想恢复默认就 reboot。
set -u

log() { echo "[crux-ufs] $*"; }

# 1) 关闭自动 hibern8（值语义=空闲多少微秒后进 hibern8，0=关闭）
UFS=/sys/devices/platform/soc@0/1d84000.ufshc
if [ -d "$UFS" ]; then
	if [ -w "$UFS/auto_hibern8" ]; then
		echo 0 > "$UFS/auto_hibern8" && log "auto_hibern8=0 ($(cat $UFS/auto_hibern8))"
	fi
	if [ -w "$UFS/clkgate_delay_ms" ]; then
		echo 1000 > "$UFS/clkgate_delay_ms" && log "clkgate_delay_ms=1000 ($(cat $UFS/clkgate_delay_ms))"
	fi
else
	log "WARN: $UFS 不存在（DT/驱动变了？）"
fi

# 2) 关闭各 UFS LUN 的 runtime autosuspend（否则 sd_shutdown 会直接 return，
#    关机时不再下发 SYNCHRONIZE CACHE）
for b in /sys/block/sd*; do
	[ -e "$b" ] || continue
	dev=$(readlink -f "$b/device" 2>/dev/null) || continue
	[ -w "$dev/power/control" ] || continue
	echo on > "$dev/power/control" && log "$b -> control=on status=$(cat $dev/power/runtime_status 2>/dev/null)"
done

# 3) 留痕（写进内核日志，重启后好核对）
log "done: hibern8=$(cat $UFS/auto_hibern8 2>/dev/null) clkgate=$(cat $UFS/clkgate_delay_ms 2>/dev/null)"
exit 0
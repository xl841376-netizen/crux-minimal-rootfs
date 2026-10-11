#!/bin/sh
# crux 2026-10-05: service400 等待已移除（与 SLPI 初始化互相死锁）
i=0
while [ "$i" -lt 30 ]; do
    i=$((i+1))
    [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" = "running" ] || { sleep 1; continue; }
    pgrep -x pd-mapper >/dev/null || { sleep 1; continue; }
    logger -t wait-dsp-ready "DSP running at ${i}s (service400 wait removed)"
    sleep 1
    exit 0
done
logger -t wait-dsp-ready "timeout waiting for remoteproc0 running"
exit 0

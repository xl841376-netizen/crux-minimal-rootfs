#!/bin/sh
# Android 等价语义：region "m9kefs1" -> 直接写 /dev/disk/by-partlabel/mdm1m9kefs1
# 需要 -W（允许写块设备）。跑之前确保 /root/x50mods/efs-bak-20261016/ 里有备份。
# 2026-10-16 按原厂 ks 语义改参数：被动等 HELLO（不主动发）+ 单块 -j 1024 (1MB)
for i in $(seq 1 240); do
    [ -e /dev/mhi_pipe_10 ] && break
    sleep 1
done
[ -e /dev/mhi_pipe_10 ] || { echo "no /dev/mhi_pipe_10"; exit 1; }
exec /usr/local/bin/mhi_efs_sync -v -d /dev/mhi_pipe_10 -o /dev/disk/by-partlabel -g mdm1 -W -j 1024 -t 0
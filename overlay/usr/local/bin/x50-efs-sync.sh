#!/bin/sh
# ks -m -l 等价：8KB分块 + 直写 /dev/disk/by-partlabel/mdm1<m9kefsX> + 常驻循环
for i in $(seq 1 200); do
  [ -e /dev/mhi_pipe_10 ] && break
  sleep 1
done
[ -e /dev/mhi_pipe_10 ] || { echo no pipe_10; exit 1; }
mkdir -p /var/lib/mhi-efs
exec python3 -u /root/x50mods/x50_efs_probe2.py /dev/mhi_pipe_10 /dev/disk/by-partlabel mdm1 1

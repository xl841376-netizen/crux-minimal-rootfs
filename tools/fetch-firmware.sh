#!/bin/sh
# 从一台"已经在跑这套系统"的设备上拉出构建镜像所需的固件与内核模块
# 用法: ./tools/fetch-firmware.sh [user@host] [输出目录] [内核版本]
#   默认: root@192.168.1.240  ./fw  7.3.0-rc5-crux73
# 说明: 固件是厂商专有文件，不在本仓库里；用这个脚本从你手上的设备取。
set -eu
HOST=${1:-root@192.168.1.240}
OUT=${2:-./fw}
KVER=${3:-7.3.0-rc5-crux73}
mkdir -p "$OUT/firmware" "$OUT/modules"
echo "== 拉 /lib/firmware（排除 _split_bak / *.bak* / *.orig）"
ssh "$HOST" "cd /lib/firmware && tar -cf - --exclude='_split_bak' --exclude='*.bak*' --exclude='*.orig' ." \
  | tar -C "$OUT/firmware" -xf -
echo "== 拉 /lib/modules/$KVER（排除 build 软链）"
ssh "$HOST" "tar -C /lib/modules -cf - --exclude='build' $KVER" | tar -C "$OUT/modules" -xf -
echo "== 完成"
du -sh "$OUT/firmware" "$OUT/modules"

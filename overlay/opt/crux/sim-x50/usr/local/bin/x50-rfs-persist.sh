#!/bin/bash
# x50-rfs-persist.sh —— 把 X50（外挂 SDX50M）的 /readwrite 根对齐到 Android 的真实落点
#   Android：/vendor/rfs/mdm/mpss/readwrite -> /mnt/vendor/persist/rfs/mdm/mpss
#   我们：  /var/lib/tqftpserv（tqftpserv 里 READWRITE_PATH 的硬编码根）-> bind 到 persist 同一目录
# 幂等；persist 以 rw 挂载（Android 上也是 rw）。
set -u

P=/dev/disk/by-partlabel/persist
PU=/dev/disk/by-partuuid/a85a682e-f2de-943a-5731-7ac3e7641b54

# wait for persist device (udev 建 by-partlabel 链接可能比本服务晚；开机实测踩过)
for i in $(seq 1 30); do
	[ -e "$P" ] && break
	if [ -e "$PU" ]; then P="$PU"; break; fi
	sleep 0.5
done
[ -e "$P" ] || { echo "x50-rfs-persist: persist device not found ($P)" >&2; exit 1; }
M=/mnt/persist
SUB=$M/rfs/mdm/mpss
RW=/var/lib/tqftpserv

mkdir -p "$M"

if ! mountpoint -q "$M"; then
	if ! mount -o rw "$P" "$M"; then
		echo "x50-rfs-persist: mount persist failed" >&2
		exit 1
	fi
else
	mount -o remount,rw "$M" 2>/dev/null
fi

mkdir -p "$SUB" "$RW"

if mountpoint -q "$RW"; then
	echo "x50-rfs-persist: $RW already bind-mounted"
	exit 0
fi

if ! mount --bind "$SUB" "$RW"; then
	echo "x50-rfs-persist: bind $SUB -> $RW failed" >&2
	exit 1
fi

echo "x50-rfs-persist: $RW -> $SUB (persist, Android-aligned)"
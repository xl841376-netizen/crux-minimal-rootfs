#!/bin/sh
# crux swap 布局（幂等，可重复执行）
#
#   所有行为都由 /etc/crux-swap.conf 的参数决定，**默认全部关闭**：
#     SWAP_ENABLE=0        -> 总闸关闭：不建 zram、不建 swapfile，并把已有 swap 全部 swapoff
#     ZRAM_MB=0            -> 即使 SWAP_ENABLE=1，也不建 zram（设为 4096 才建）
#     LROOT_SWAP=0         -> 即使 SWAP_ENABLE=1，也不建磁盘 swapfile（需另有一块 PARTLABEL=linux-root）
#
#   设计原因：本机根分区本身就可能叫 linux-root，
#   磁盘 swapfile 依赖“另一块盘”，不能默认去碰分区。需要时显式打开。
set -u

CONF=/etc/crux-swap.conf

# ---------- 默认值（安全侧：全关）----------
SWAP_ENABLE=0
ZRAM_MB=0
ZRAM_PRIO=100
LROOT_SWAP=0
LROOT_SWAP_MB=8192
SWAPFILE_PRIO=10
SWAPPINESS=100
PAGE_CLUSTER=0
WATERMARK_BOOST=0

if [ -r "$CONF" ]; then
    . "$CONF" 2>/dev/null || true
fi

SWAPDIR=/mnt/lroot
SWAPFILE=$SWAPDIR/swapfile
K=$(uname -r)
E=/lib/modules/$K/extra

log() { echo "[crux-swap] $*"; }

log "conf: $CONF  SWAP_ENABLE=$SWAP_ENABLE ZRAM_MB=$ZRAM_MB LROOT_SWAP=$LROOT_SWAP(${LROOT_SWAP_MB}MiB)"

# ---------- 0) 总闸关闭：清理并退出 ----------
if [ "$SWAP_ENABLE" != "1" ]; then
    log "SWAP_ENABLE=$SWAP_ENABLE -> swap 全部禁用"
    if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
        swapoff -a 2>/dev/null && log "swapoff -a 完成"
    else
        log "当前没有启用中的 swap"
    fi
    sysctl -qw vm.swappiness=60 vm.page-cluster=3 vm.watermark_boost_factor=15000 2>/dev/null
    log "sysctl: swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null) page-cluster=$(cat /proc/sys/vm/page-cluster 2>/dev/null)"
    log "=== swapon --show ==="
    swapon --show
    log "=== meminfo ==="
    grep -E "MemTotal|SwapTotal|SwapFree" /proc/meminfo
    exit 0
fi

# ---------- 1) zram（ZRAM_MB>0 才建）----------
if [ "${ZRAM_MB:-0}" -gt 0 ] 2>/dev/null; then
    if [ ! -e /dev/zram0 ]; then
        modprobe zsmalloc 2>/dev/null || insmod $E/zsmalloc.ko 2>/dev/null
        modprobe zram 2>/dev/null || insmod $E/zram.ko 2>/dev/null
        sleep 1
    fi
    if [ -e /dev/zram0 ]; then
        if ! grep -q "/dev/zram0" /proc/swaps; then
            for c in zstd lz4 lzo-rle lzo; do
                if echo "$c" > /sys/block/zram0/comp_algorithm 2>/dev/null; then
                    log "zram compressor: $c"
                    break
                fi
            done
            echo ${ZRAM_MB}M > /sys/block/zram0/disksize 2>/dev/null || \
                echo $((ZRAM_MB * 1024 * 1024)) > /sys/block/zram0/disksize
            mkswap /dev/zram0 >/dev/null 2>&1
            swapon -p "$ZRAM_PRIO" /dev/zram0 && log "zram0 (${ZRAM_MB}MiB) swapon ok"
        else
            log "zram0 already in use"
        fi
    else
        log "ERROR: no /dev/zram0 (zram module missing?)"
    fi
else
    log "ZRAM_MB=$ZRAM_MB -> 跳过 zram"
fi

# ---------- 2) 磁盘 swapfile（LROOT_SWAP=1 且根不是 linux-root 才做）----------
ROOT_PL=$(lsblk -no PARTLABEL "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
if [ "$LROOT_SWAP" = "1" ]; then
    if [ "$ROOT_PL" = "linux-root" ]; then
        log "WARN: / 所在分区 PARTLABEL 就是 linux-root，无法再作为 $SWAPDIR，跳过磁盘 swapfile"
        LROOT_SWAP=0
    fi
fi

if [ "$LROOT_SWAP" = "1" ]; then
    log "LROOT_SWAP=1 -> 使用 $SWAPDIR 上的 ${LROOT_SWAP_MB}MiB swapfile"
    mkdir -p $SWAPDIR
    if ! mountpoint -q $SWAPDIR; then
        mount /dev/disk/by-partlabel/linux-root $SWAPDIR 2>/dev/null && log "mounted linux-root at $SWAPDIR"
    fi
    if mountpoint -q $SWAPDIR; then
        if [ ! -f $SWAPFILE ]; then
            log "creating $SWAPFILE (${LROOT_SWAP_MB}MiB) ..."
            if ! fallocate -l ${LROOT_SWAP_MB}M $SWAPFILE 2>/dev/null; then
                dd if=/dev/zero of=$SWAPFILE bs=1M count=$LROOT_SWAP_MB status=none
            fi
            chmod 600 $SWAPFILE
            mkswap $SWAPFILE >/dev/null
        fi
        if ! grep -q " $SWAPFILE " /proc/swaps; then
            swapon -p "$SWAPFILE_PRIO" $SWAPFILE && log "swapfile ${LROOT_SWAP_MB}MiB swapon ok"
        else
            log "swapfile already in use"
        fi
    else
        log "ERROR: $SWAPDIR not mounted, skip swapfile"
    fi
else
    log "LROOT_SWAP=0 -> 跳过磁盘 swapfile"
fi

# ---------- 3) 内核参数（仅启用 swap 时应用）----------
sysctl -qw vm.swappiness=$SWAPPINESS vm.page-cluster=$PAGE_CLUSTER vm.watermark_boost_factor=$WATERMARK_BOOST 2>/dev/null
log "sysctl: swappiness=$(cat /proc/sys/vm/swappiness) page-cluster=$(cat /proc/sys/vm/page-cluster)"

# ---------- 4) 汇总 ----------
log "=== swapon --show ==="
swapon --show
log "=== meminfo ==="
grep -E "MemTotal|SwapTotal|SwapFree" /proc/meminfo
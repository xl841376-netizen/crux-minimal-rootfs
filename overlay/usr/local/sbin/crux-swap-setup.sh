#!/bin/sh
# crux swap 布局：zram 4GiB（zstd，优先级高）+ sda36(linux-root) 上 8GiB swapfile = 合计 12GiB
# 幂等：可重复执行
set -u
ZRAM_MB=4096
SWAPDIR=/mnt/lroot
SWAPFILE=$SWAPDIR/swapfile
SWAPFILE_SIZE=8G
K=$(uname -r)
E=/lib/modules/$K/extra

log() { echo "[crux-swap] $*"; }

# ---------- 1) zram ----------
if [ ! -e /dev/zram0 ]; then
    modprobe zsmalloc 2>/dev/null || insmod $E/zsmalloc.ko 2>/dev/null
    modprobe zram 2>/dev/null || insmod $E/zram.ko 2>/dev/null
    sleep 1
fi
if [ -e /dev/zram0 ]; then
    if ! grep -q "/dev/zram0" /proc/swaps; then
        # 优先 zstd，退回 lz4 / lzo-rle
        for c in zstd lz4 lzo-rle lzo; do
            if echo "$c" > /sys/block/zram0/comp_algorithm 2>/dev/null; then
                log "zram compressor: $c"
                break
            fi
        done
        echo ${ZRAM_MB}M > /sys/block/zram0/disksize 2>/dev/null || \
            echo $((ZRAM_MB * 1024 * 1024)) > /sys/block/zram0/disksize
        mkswap /dev/zram0 >/dev/null 2>&1
        swapon -p 100 /dev/zram0 && log "zram0 (${ZRAM_MB}MiB) swapon ok"
    else
        log "zram0 already in use"
    fi
else
    log "ERROR: no /dev/zram0 (zram module missing?)"
fi

# ---------- 2) 磁盘 swapfile ----------
mkdir -p $SWAPDIR
if ! mountpoint -q $SWAPDIR; then
    mount /dev/disk/by-partlabel/linux-root $SWAPDIR 2>/dev/null && log "mounted linux-root at $SWAPDIR"
fi
if mountpoint -q $SWAPDIR; then
    if [ ! -f $SWAPFILE ]; then
        log "creating $SWAPFILE ($SWAPFILE_SIZE) ..."
        if ! fallocate -l $SWAPFILE_SIZE $SWAPFILE 2>/dev/null; then
            dd if=/dev/zero of=$SWAPFILE bs=1M count=8192 status=none
        fi
        chmod 600 $SWAPFILE
        mkswap $SWAPFILE >/dev/null
    fi
    if ! grep -q " $SWAPFILE " /proc/swaps; then
        swapon -p 10 $SWAPFILE && log "swapfile 8GiB swapon ok"
    else
        log "swapfile already in use"
    fi
else
    log "ERROR: $SWAPDIR not mounted, skip swapfile"
fi

# ---------- 3) 内核参数 ----------
sysctl -qw vm.swappiness=100 vm.page-cluster=0 vm.watermark_boost_factor=0 2>/dev/null
log "sysctl: swappiness=$(cat /proc/sys/vm/swappiness) page-cluster=$(cat /proc/sys/vm/page-cluster)"

# ---------- 4) 汇总 ----------
log "=== swapon --show ==="
swapon --show
log "=== meminfo ==="
grep -E "MemTotal|SwapTotal|SwapFree" /proc/meminfo
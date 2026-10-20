#!/bin/sh
# crux swap 布局（幂等，可重复执行）：
#   1) zram 4GiB（zstd，优先级 100）            —— 默认启用，不依赖任何分区
#   2) sda36(linux-root) 上的 8GiB swapfile     —— **由开关控制，默认关闭**
#
#   开关文件：/etc/crux-swap.conf   里 LROOT_SWAP=1 才启用第 2 项
#   为什么默认关：这个 swapfile 需要第二块盘（PARTLABEL=linux-root，本机 sda36，64G）。
#   这块盘不一定存在、也不一定长期保留（可以删掉并入根分区），默认不去碰它，
#   只用 zram。需要更大交换空间时把 LROOT_SWAP 改成 1 即可。
set -u

CONF=/etc/crux-swap.conf
LROOT_SWAP=0
if [ -r "$CONF" ]; then
    v=$(sed -n 's/^[[:space:]]*LROOT_SWAP[[:space:]]*=[[:space:]]*//p' "$CONF" | tail -1 | tr -d '[:space:]"'"'"'')
    [ -n "$v" ] && LROOT_SWAP=$v
fi

ZRAM_MB=4096
SWAPDIR=/mnt/lroot
SWAPFILE=$SWAPDIR/swapfile
SWAPFILE_SIZE=8G
K=$(uname -r)
E=/lib/modules/$K/extra

log() { echo "[crux-swap] $*"; }
log "LROOT_SWAP=$LROOT_SWAP (conf: $CONF)"

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

# ---------- 2) 磁盘 swapfile（受 /etc/crux-swap.conf 的 LROOT_SWAP 开关控制）----------
if [ "$LROOT_SWAP" = "1" ]; then
    log "LROOT_SWAP=1 -> 使用 $SWAPDIR 上的 $SWAPFILE_SIZE swapfile"
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
else
    log "LROOT_SWAP=0（默认）：跳过 $SWAPDIR 上的 swapfile，只使用 zram"
fi

# ---------- 3) 内核参数 ----------
sysctl -qw vm.swappiness=100 vm.page-cluster=0 vm.watermark_boost_factor=0 2>/dev/null
log "sysctl: swappiness=$(cat /proc/sys/vm/swappiness) page-cluster=$(cat /proc/sys/vm/page-cluster)"

# ---------- 4) 汇总 ----------
log "=== swapon --show ==="
swapon --show
log "=== meminfo ==="
grep -E "MemTotal|SwapTotal|SwapFree" /proc/meminfo
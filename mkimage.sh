#!/bin/bash
# ============================================================
#  crux（Xiaomi Mi 9 Pro 5G / SM8150）完整 rootfs 打包
#  产物：一个 tar.zst，解压到根分区即可开机（内核/dtb/initramfs 不放这里）
#
#  用法:  sudo ./mkimage.sh <输出目录> [选项]
#  先准备固件（固件是厂商专有的，不在仓库里）:
#         ./tools/fetch-firmware.sh root@<设备IP> ./fw
#
#  选项:
#    --suite resolute        Ubuntu 版本（默认 resolute = 26.04）
#    --mirror <url>          源（默认清华 ports 镜像；官方 ports.ubuntu.com 在境内常不通）
#    --level standard        基础包档位 minimal|standard|full（默认 standard，见 §1.1）
#    --kver <版本>           内核版本号（默认 7.3.0-rc5-crux73），决定模块目录
#    --fw-dir <目录>         fetch-firmware.sh 的产物目录（内含 firmware/ 与 modules/）
#    --no-fw                 不打包固件/模块（只有干净 Ubuntu 系统 + 适配层）
#  环境: ROOT_PASS（默认 root）
# ============================================================
set -euo pipefail

OUT=${1:?用法: sudo ./mkimage.sh <输出目录> [选项]}
shift || true
HERE=$(cd "$(dirname "$0")" && pwd)
SUITE=resolute
MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
LEVEL=standard
KVER=7.3.0-rc5-crux73
FW_DIR=""
WITH_FW=1
ROOT_PASS=${ROOT_PASS:-root}

while [ $# -gt 0 ]; do
  case "$1" in
    --suite) SUITE=$2; shift 2;;
    --mirror) MIRROR=$2; shift 2;;
    --level) LEVEL=$2; shift 2;;
    --kver) KVER=$2; shift 2;;
    --fw-dir) FW_DIR=$2; shift 2;;
    --no-fw) WITH_FW=0; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 1; }
command -v debootstrap >/dev/null || { echo "缺 debootstrap: apt-get install -y debootstrap zstd"; exit 1; }
LIST="$HERE/deps/lists/$LEVEL.list"
[ -f "$LIST" ] || { echo "找不到 $LIST"; exit 1; }
PKGS=$(grep -vE '^[[:space:]]*(#|$)' "$LIST" | tr '\n' ' ')

if [ "$WITH_FW" = 1 ] && [ -z "$FW_DIR" ]; then
  echo "!! 未给 --fw-dir：将生成「无固件/无模块」的包（开机后 WiFi/音频/GPU 不会工作）"
  echo "   建议先: ./tools/fetch-firmware.sh root@<设备IP> ./fw 然后 --fw-dir ./fw"
fi

mkdir -p "$OUT"
WORK=$(mktemp -d /root/.mkimage.XXXXXX)
RFS=$WORK/rfs
trap 'umount "$RFS/dev" "$RFS/proc" "$RFS/sys" 2>/dev/null || true' EXIT

echo "== [1/6] debootstrap $SUITE/$ARCH minbase"
debootstrap --arch=arm64 --variant=minbase --include=ca-certificates "$SUITE" "$RFS" "$MIRROR"

echo "== [2/6] 装 L1 必备包（$LEVEL）"
cat > "$RFS/etc/apt/sources.list" <<SL
deb $MIRROR $SUITE main universe
deb $MIRROR $SUITE-updates main universe
SL
mount --bind /dev "$RFS/dev" 2>/dev/null || true
mount -t proc proc "$RFS/proc" 2>/dev/null || true
mount -t sysfs sys "$RFS/sys" 2>/dev/null || true
chroot "$RFS" /bin/bash -e <<CHROOT
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get update -qq
apt-get install -y --no-install-recommends $PKGS
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

echo "== [3/6] 套 overlay/"
tar -C "$RFS" -cf - --exclude='*.bak*' -C "$HERE/overlay" . | tar -C "$RFS" -xf -
chmod +x "$RFS"/usr/local/bin/* "$RFS"/usr/local/sbin/* 2>/dev/null || true

echo "== [4/6] 固件 + 内核模块"
if [ "$WITH_FW" = 1 ] && [ -n "$FW_DIR" ]; then
  mkdir -p "$RFS/lib/firmware" "$RFS/lib/modules"
  cp -a "$FW_DIR/firmware/." "$RFS/lib/firmware/"
  cp -a "$FW_DIR/modules/." "$RFS/lib/modules/"
  find "$RFS/lib/modules" "$RFS/lib/firmware" \( -name '*.bak*' -o -name '*.orig' \) -delete

  # ---------- 模块路径归一：extra/ -> kernel/（与内核树内一致）----------
  # 目的：固件资产（fw-* Release）里的模块可能还是树外编的布局，放在
  #       /lib/modules/$KVER/extra/ 下；而内核树内编出来的对应模块在
  #       kernel/drivers/crux/ 与 kernel/drivers/net/ipa/ 下。
  #       同名两份会让 depmod 告警并按 modules.dep 二选一，结果不确定。
  #       这里统一搬到内核树内路径：kernel/ 已有同名 -> 删 extra 副本；
  #       否则搬过去（兼容旧资产，保证云端产物与设备一致）。
  MOD="$RFS/lib/modules/$KVER"
  if [ -d "$MOD/extra" ]; then
    moved=0; dropped=0
    for ko in "$MOD/extra"/*.ko; do
      [ -e "$ko" ] || continue
      b=$(basename "$ko")
      case "$b" in
        crux_esoc.ko|npucc-sm8150.ko) dst="$MOD/kernel/drivers/crux" ;;
        msm_npu.ko)                   dst="$MOD/kernel/drivers/crux/npu" ;;
        ipa_mhi_proxy.ko)             dst="$MOD/kernel/drivers/net/ipa" ;;
        *) continue ;;
      esac
      if [ -e "$dst/$b" ]; then
        rm -f "$ko"; dropped=$((dropped + 1))
      else
        mkdir -p "$dst"; mv -f "$ko" "$dst/"; moved=$((moved + 1))
      fi
    done
    find "$MOD/extra" -name '*.bak*' -delete 2>/dev/null || true
    rmdir "$MOD/extra" 2>/dev/null || true
    echo "   模块归一: 移动 $moved 个 / 去重 $dropped 个（extra/ 已清空）"
  fi

  # 重算模块依赖（必须：否则 modules.dep 仍指向 extra/ 下的旧路径）
  if [ -x "$RFS/usr/sbin/depmod" ]; then
    if chroot "$RFS" /usr/sbin/depmod -a "$KVER" 2>/dev/null; then
      echo "   depmod: ok（modules.dep $(wc -l < "$MOD/modules.dep" 2>/dev/null || echo '?') 条）"
    else
      echo "   depmod: !! 失败（模块依赖可能不准）"
    fi
  fi
fi

echo "== [5/6] 系统配置"
cat > "$RFS/etc/fstab" <<FSTAB
# 根分区：写分区时把 PARTLABEL 设成 linux-root26（与在役设备一致）
PARTLABEL=linux-root26  /  ext4  defaults,noatime,errors=remount-ro  0 1
# [可选] 第二块盘用作 8G swapfile 落点（默认不需要，见 /etc/crux-swap.conf）
# PARTLABEL=linux-root  /mnt/lroot  ext4  defaults,noatime,nofail  0 2
FSTAB
echo crux > "$RFS/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 crux\n::1 localhost ip6-localhost ip6-loopback\n' > "$RFS/etc/hosts"
mkdir -p "$RFS/root/.ssh"; chmod 700 "$RFS/root/.ssh"
chroot "$RFS" /bin/bash -c "echo 'root:$ROOT_PASS' | chpasswd"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$RFS/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$RFS/etc/ssh/sshd_config"

UNITS="rmtfs tqftpserv pd-mapper hexagonrpcd-sdsp crux-ssc-registry iris-vpu npu-svc crux-fastrpc-guard crux-touch-watchdog usb-gadget-acm usb-align qsee-supplicant modem-mnt qcom-subsys-start crux-audio-route crux-time-sync crux-swap crux-ufs-stable ufs-nopm crux-charger-init crux-crashsave crux-markshutdown crux-kmsg-tap dmesg-snap power-snap"
TIMERS="crux-time-sync.timer qcom-subsys-start.timer"
ok=0; fail=""
for u in $UNITS; do systemctl --root="$RFS" enable "$u.service" >/dev/null 2>&1 && ok=$((ok+1)) || fail="$fail $u"; done
for t in $TIMERS; do systemctl --root="$RFS" enable "$t" >/dev/null 2>&1 && ok=$((ok+1)) || fail="$fail $t"; done
echo "   已启用 $ok 个单元/定时器；失败:${fail:- 无}"

umount "$RFS/dev" "$RFS/proc" "$RFS/sys" 2>/dev/null || true
rm -rf "$RFS/tmp/"* "$RFS/var/tmp/"* "$RFS/var/log/"* 2>/dev/null || true
: > "$RFS/etc/machine-id"
rm -f "$RFS"/etc/ssh/ssh_host_* 2>/dev/null || true
mkdir -p "$RFS/var/log"

echo "== [6/6] 打包"
NAME="crux-rootfs-${SUITE}-arm64-$(date +%Y%m%d)"
( cd "$RFS" && tar -I "zstd -19 -T0" -cf "$OUT/$NAME.tar.zst" . )
( cd "$OUT" && sha256sum "$NAME.tar.zst" > SHA256SUMS )
echo "== 完成: $OUT/$NAME.tar.zst  $(du -h "$OUT/$NAME.tar.zst" | cut -f1)"
echo "   大小明细: 系统+包 $(du -sh --exclude=lib/firmware --exclude=lib/modules "$RFS" | cut -f1) / 固件 $(du -sh "$RFS/lib/firmware" 2>/dev/null | cut -f1) / 模块 $(du -sh "$RFS/lib/modules" 2>/dev/null | cut -f1)"

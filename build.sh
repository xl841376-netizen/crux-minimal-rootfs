#!/bin/bash
# ============================================================
#  crux（Xiaomi Mi 9 Pro 5G / SM8150）最小 rootfs 构建脚本
#  用法:  sudo ./build.sh <目标目录>
#  环境:  SUITE=resolute  (Ubuntu 26.04)  MIRROR=http://ports.ubuntu.com/ubuntu-ports
#         ARCH=arm64   ROOT_PASS=root  (root 通用密码，可覆盖)
# ============================================================
set -euo pipefail

DEST=${1:?用法: sudo ./build.sh <目标目录>}
HERE=$(cd "$(dirname "$0")" && pwd)
SUITE=${SUITE:-resolute}
MIRROR=${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
ARCH=${ARCH:-arm64}
ROOT_PASS=${ROOT_PASS:-root}

# 需要开机启用的设备适配服务
UNITS="rmtfs tqftpserv pd-mapper hexagonrpcd-sdsp crux-ssc-registry iris-vpu \
npu-svc crux-fastrpc-guard crux-touch-watchdog usb-gadget-acm usb-align qsee-supplicant \
modem-mnt qcom-subsys-start crux-audio-route crux-time-sync \
crux-swap crux-ufs-stable ufs-nopm crux-charger-init crux-crashsave crux-markshutdown \
crux-kmsg-tap dmesg-snap power-snap"

# 定时器（挂在 timers.target 上）
TIMERS="crux-time-sync.timer qcom-subsys-start.timer"

# 注意：SIM / 外挂 X50（sdx50m）那一整套【不在这里启用】。
#   overlay/opt/crux/sim-x50/ 里按系统路径镜像保存着全部 x50-* 单元与程序，
#   但它们落在 /opt/crux/sim-x50，不会自动生效；需要时在设备上执行：
#       crux-sim-x50 enable      # 铺回 /etc、/usr/local 并 enable
#       crux-sim-x50 status      # 查看
#       crux-sim-x50 disable     # 撤掉
#   默认值记录在 /etc/crux-sim.conf 的 SIM_X50_ENABLE=0。

need() { command -v "$1" >/dev/null || { echo "缺少 $1，请先 apt-get install -y $2"; exit 1; }; }
need debootstrap debootstrap

echo "== [1/6] debootstrap $SUITE/$ARCH -> $DEST =="
mkdir -p "$DEST"
debootstrap --arch="$ARCH" --variant=minbase --include=ca-certificates \
            "$SUITE" "$DEST" "$MIRROR"

echo "== [2/6] 基础系统（systemd / 网络 / 工具） =="
mount --bind /dev  "$DEST/dev"  2>/dev/null || true
mount -t proc proc "$DEST/proc" 2>/dev/null || true
mount -t sysfs sys "$DEST/sys"  2>/dev/null || true

cat > "$DEST/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main universe
EOF

chroot "$DEST" /bin/bash -e <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  systemd systemd-sysv udev kmod \
  iproute2 iputils-ping net-tools ethtool \
  network-manager wpasupplicant rfkill \
  openssh-server sudo python3 less nano \
  modemmanager libqmi-utils \
  e2fsprogs dosfstools
apt-get clean
CHROOT

echo "== [3/6] 套用设备适配层 overlay/ =="
tar -C "$DEST" -cf - --exclude='*.bak*' -C "$HERE/overlay" . | tar -C "$DEST" -xf -
chmod +x "$DEST"/usr/local/bin/* "$DEST"/usr/local/sbin/* 2>/dev/null || true

echo "== [4/6] 安装设备专用内核模块 =="
KVER=$(ls "$DEST/usr/lib/modules" 2>/dev/null | head -1 || true)
if [ -n "$KVER" ]; then
  MODDIR="$DEST/usr/lib/modules/$KVER/extra"
else
  MODDIR="$DEST/usr/lib/modules/extra"      # 内核未装时先放临时位置
fi
mkdir -p "$MODDIR"
cp -v "$HERE"/modules/*.ko "$MODDIR"/

echo "== [5/6] 启用设备适配服务 =="
for u in $UNITS; do
  systemctl --root="$DEST" enable "$u.service" >/dev/null 2>&1 \
    && echo "  enabled $u" || echo "  !! 启用失败: $u"
done
for t in $TIMERS; do
  systemctl --root="$DEST" enable "$t" >/dev/null 2>&1 \
    && echo "  enabled $t" || echo "  !! 启用失败: $t"
done
echo "  （npu-boot.service 默认不启用，需要时手动 systemctl enable）"
echo "  （SIM/X50 整套默认不启用，需要时执行 crux-sim-x50 enable）"

echo "== [6/6] 基本配置 =="
echo crux > "$DEST/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 crux\n::1 localhost ip6-localhost ip6-loopback\n' > "$DEST/etc/hosts"
cat > "$DEST/etc/fstab" <<'EOF'
# <根分区> 必须是设备的 linux-root* 分区；UUID 用 blkid 查
# UUID=<在此填写> / ext4 defaults,noatime 0 1
#
# [可选] 第二块盘（sda36, PARTLABEL=linux-root 64G）用作 8G swapfile 的落点。
#        默认【不需要】：/etc/crux-swap.conf 里 LROOT_SWAP=0（默认），
#        crux-swap 只建 zram 4G，不依赖任何分区。
#        想在它上面加 8G swapfile 时：① 去掉下面这行注释；② 把
#        /etc/crux-swap.conf 改成 LROOT_SWAP=1；③ systemctl restart crux-swap
# PARTLABEL=linux-root /mnt/lroot ext4 defaults,noatime,nofail 0 2
EOF
[ -d "$DEST/root" ] || mkdir -p "$DEST/root"
mkdir -p "$DEST/root/.ssh"; chmod 700 "$DEST/root/.ssh"

# --- root 通用密码（默认 root，可用 ROOT_PASS=... 覆盖）---
chroot "$DEST" /bin/bash -e <<CHROOT
 echo "root:$ROOT_PASS" | chpasswd
CHROOT
# 允许 root 用密码或 key 登录（设备调试用）
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$DEST/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$DEST/etc/ssh/sshd_config"
grep -E '^(PermitRootLogin|PasswordAuthentication)' "$DEST/etc/ssh/sshd_config"
echo "  root 通用密码已设为: $ROOT_PASS （务必登录后改掉）"

umount "$DEST/dev" "$DEST/proc" "$DEST/sys" 2>/dev/null || true

cat <<EOF

完成。剩余两步（在宿主/内核树里做）：
 1) 装内核模块与固件：
    make O=build73 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \\
         modules_install INSTALL_MOD_PATH=$DEST
 2) 写 /etc/fstab 的 root UUID、在 ESP 的 EFI/crux/grub.cfg 里给出对应 root=UUID=…
EOF
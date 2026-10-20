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
ARCH=arm64
SELECTIONS=""          # --selections <文件>：按 dpkg 包清单安装（优先于 --level）
PRIVATE_DIR=""         # --private <目录>：私有配置（WiFi 密码、ssh 公钥等），不入库
ROOT_UUID=""           # --root-uuid <uuid>：写入 fstab 的根分区 UUID（优先）
ROOT_LABEL="linux-root"    # --root-label <label>：无 UUID 时用标签
FSTAB_ROOT="PARTLABEL=linux-root"
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
    --selections) SELECTIONS=$2; shift 2;;
    --private) PRIVATE_DIR=$2; shift 2;;
    --root-uuid) ROOT_UUID=$2; shift 2;;
    --root-label) ROOT_LABEL=$2; shift 2;;
    --no-fw) WITH_FW=0; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 1; }
command -v debootstrap >/dev/null || { echo "缺 debootstrap: apt-get install -y debootstrap zstd"; exit 1; }
if [ -n "$SELECTIONS" ]; then
  [ -f "$SELECTIONS" ] || { echo "找不到包清单 $SELECTIONS"; exit 1; }
  echo "== 包来源: selections ($SELECTIONS)"
  PKGS=$(grep -vE '^[[:space:]]*(#|$)' "$SELECTIONS" | awk '{print $1}' | tr '\n' ' ')
else
  LIST="$HERE/deps/lists/$LEVEL.list"
  [ -f "$LIST" ] || { echo "找不到 $LIST"; exit 1; }
  echo "== 包来源: level=$LEVEL ($LIST)"
  PKGS=$(grep -vE '^[[:space:]]*(#|$)' "$LIST" | tr '\n' ' ')
fi

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
if [ -n "$SELECTIONS" ]; then
    echo "   使用包清单: $SELECTIONS（$([ -f "$SELECTIONS" ] && wc -l < "$SELECTIONS" || echo 0) 个包）"
fi

cat > "$RFS/etc/apt/sources.list" <<SL
deb $MIRROR $SUITE main universe
deb $MIRROR $SUITE-updates main universe
SL
mount --bind /dev "$RFS/dev" 2>/dev/null || true
mount -t proc proc "$RFS/proc" 2>/dev/null || true
mount -t sysfs sys "$RFS/sys" 2>/dev/null || true
# 计算 fstab 根分区写法
if [ -n "$ROOT_UUID" ]; then
  FSTAB_ROOT="UUID=$ROOT_UUID"
else
  FSTAB_ROOT="PARTLABEL=$ROOT_LABEL"
fi

# 包清单落盘（避免 heredoc 变量提前展开），安装逻辑放进 chroot 内执行
printf '%s\n' $PKGS > "$RFS/root/_pkgs.txt"
cat > "$RFS/root/_install_pkgs.sh" <<'EOS'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get update -qq
PKGS=$(cat /root/_pkgs.txt | tr '\n' ' ')
echo "   待装包数: $(wc -l < /root/_pkgs.txt)"
if apt-get install -y --no-install-recommends $PKGS; then
    echo "   整包安装成功"
    exit 0
fi
echo "   !! 整包安装失败，改为逐包安装（缺失的记录下来）"
n=0
: > /root/_missing.txt
for p in $PKGS; do
    apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 || { echo "$p" >> /root/_missing.txt; n=$((n+1)); }
done
echo "   逐包安装完成，缺失 $n 个"
exit 0
EOS
chmod +x "$RFS/root/_install_pkgs.sh"
chroot "$RFS" /bin/bash /root/_install_pkgs.sh || { echo "!! 包安装失败"; exit 1; }

chroot "$RFS" /bin/bash -e <<CHROOT
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

# 把缺失清单带出到输出目录，便于排查
if [ -s "$RFS/root/_missing.txt" ]; then
    mkdir -p "$OUT"
    cp "$RFS/root/_missing.txt" "$OUT/missing-packages.txt"
    echo "   缺失包清单: $OUT/missing-packages.txt（$(wc -l < "$RFS/root/_missing.txt") 个）"
fi
rm -f "$RFS/root/_missing.txt"

echo "== [3/6] 套 overlay/"
tar -C "$RFS" -cf - --exclude='*.bak*' -C "$HERE/overlay" . | tar -C "$RFS" -xf -
chmod +x "$RFS"/usr/local/bin/* "$RFS"/usr/local/sbin/* 2>/dev/null || true

# ---- 私有配置（不入库：WiFi 密码 / ssh 公钥 / 机器专属配置）----
if [ -n "$PRIVATE_DIR" ]; then
  [ -d "$PRIVATE_DIR" ] || { echo "!! --private 目录不存在: $PRIVATE_DIR"; exit 1; }
  echo "   套用私有配置: $PRIVATE_DIR"
  tar -C "$RFS" -cf - -C "$PRIVATE_DIR" . | tar -C "$RFS" -xf -
  # netplan 里有密码，收权限
  [ -d "$RFS/etc/netplan" ] && chmod 600 "$RFS"/etc/netplan/*.yaml 2>/dev/null || true
fi

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
      { [ -e "$ko" ] || [ -L "$ko" ]; } || continue
      b=$(basename "$ko")
      case "$b" in
        crux_esoc.ko|npucc-sm8150.ko) dst="$MOD/kernel/drivers/crux" ;;
        msm_npu.ko)                   dst="$MOD/kernel/drivers/crux/npu" ;;
        ipa_mhi_proxy.ko)             dst="$MOD/kernel/drivers/net/ipa" ;;
        *) continue ;;
      esac
      # 软链（固件资产里常见：extra/xxx.ko -> /lib/modules/<kver>/kernel/...）
      # 解压后指向构建机绝对路径，会悬空。kernel/ 下通常已有同名实体文件，
      # 因此软链一律删除（去重），不跟随。
      if [ -L "$ko" ]; then
        if [ -e "$dst/$b" ]; then
          rm -f "$ko"; dropped=$((dropped + 1))
        else
          echo "   !! 警告: $b 是软链且 kernel/ 下无同名文件，丢弃（模块可能缺失，请重取固件资产）"
          rm -f "$ko"; dropped=$((dropped + 1))
        fi
        continue
      fi

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
# 根分区：优先用 UUID（由 --root-uuid 指定），否则用标签 --root-label
${FSTAB_ROOT}  /  ext4  defaults,noatime,errors=remount-ro  0 1
# [可选] 第二块盘用作 8G swapfile 落点（默认不需要，见 /etc/crux-swap.conf）
# PARTLABEL=linux-root  /mnt/lroot  ext4  defaults,noatime,nofail  0 2
FSTAB
echo crux > "$RFS/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 crux\n::1 localhost ip6-localhost ip6-loopback\n' > "$RFS/etc/hosts"
mkdir -p "$RFS/root/.ssh"; chmod 700 "$RFS/root/.ssh"
chroot "$RFS" /bin/bash -c "echo 'root:$ROOT_PASS' | chpasswd"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$RFS/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$RFS/etc/ssh/sshd_config"

# ---- ssh 必开：显式 enable ssh.service（Ubuntu 24+ 只给 ssh.socket，socket 链断则 22 不监听）----
if [ -f "$RFS/usr/lib/systemd/system/ssh.service" ]; then
  mkdir -p "$RFS/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/ssh.service "$RFS/etc/systemd/system/multi-user.target.wants/ssh.service"
  echo "   已 enable ssh.service（multi-user.target.wants）"
fi

# ---- crux 用户（桌面登录用；组与在役机器一致）----
if ! chroot "$RFS" id crux >/dev/null 2>&1; then
  chroot "$RFS" /bin/bash -c "useradd -m -s /bin/bash -G sudo,audio,video,input,render,netdev,dialout,lp,tty crux && echo 'crux:${CRUX_PASS:-crux}' | chpasswd" \
    && echo "   已创建用户 crux（组: sudo,audio,video,input,render,netdev,dialout,lp,tty）"
fi

# ---- 时区 / locale（对齐在役机器）----
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$RFS/etc/localtime"
echo Asia/Shanghai > "$RFS/etc/timezone"
printf 'LANG=zh_CN.UTF-8\nLANGUAGE=zh_CN:zh\n' > "$RFS/etc/default/locale"
if [ -x "$RFS/usr/sbin/locale-gen" ]; then
  chroot "$RFS" locale-gen zh_CN.UTF-8 >/dev/null 2>&1 || true
fi

# ---- 桌面/输入法环境（GNOME + ibus）----
mkdir -p "$RFS/etc/environment.d"
cat > "$RFS/etc/environment.d/10-crux-desktop.conf" <<'ENVEOF'
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
LANG=zh_CN.UTF-8
ENVEOF

UNITS="gdm3 ssh rmtfs tqftpserv pd-mapper hexagonrpcd-sdsp crux-ssc-registry iris-vpu npu-svc crux-fastrpc-guard crux-touch-watchdog usb-gadget-acm usb-align qsee-supplicant modem-mnt qcom-subsys-start crux-audio-route crux-time-sync crux-swap crux-ufs-stable ufs-nopm crux-charger-init crux-crashsave crux-markshutdown crux-kmsg-tap dmesg-snap power-snap"
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

# ---- 权限归一（否则 sshd StrictModes 会拒绝公钥登录、sudo 会报错）----
chmod 755 "$RFS/root" 2>/dev/null || true
chown root:root "$RFS/root" 2>/dev/null || true
[ -d "$RFS/root/.ssh" ] && chmod 700 "$RFS/root/.ssh" && chown -R root:root "$RFS/root/.ssh"
[ -f "$RFS/root/.ssh/authorized_keys" ] && chmod 600 "$RFS/root/.ssh/authorized_keys"
# 家目录也不能 world-writable
for d in "$RFS"/home/*; do
  [ -d "$d" ] || continue
  chmod 755 "$d" 2>/dev/null || true
done
# 全局扫一遍：/ 下不允许 777 的顶层目录（tar 解包常带出 777）
for d in "$RFS"/*; do
  [ -d "$d" ] || continue
  m=$(stat -c %a "$d" 2>/dev/null || echo 755)
  case "$m" in *777*) echo "   修正 777: ${d#$RFS} ($m -> 755)"; chmod 755 "$d";; esac
done
echo "   权限归一完成：/root=$(stat -c %a "$RFS/root" 2>/dev/null)"

echo "== [6/6] 打包"
NAME="crux-rootfs-${SUITE}-arm64-$(date +%Y%m%d)"
( cd "$RFS" && tar -I "zstd -19 -T0" -cf "$OUT/$NAME.tar.zst" . )
( cd "$OUT" && sha256sum "$NAME.tar.zst" > SHA256SUMS )
echo "== 完成: $OUT/$NAME.tar.zst  $(du -h "$OUT/$NAME.tar.zst" | cut -f1)"
echo "   大小明细: 系统+包 $(du -sh --exclude=lib/firmware --exclude=lib/modules "$RFS" | cut -f1) / 固件 $(du -sh "$RFS/lib/firmware" 2>/dev/null | cut -f1) / 模块 $(du -sh "$RFS/lib/modules" 2>/dev/null | cut -f1)"

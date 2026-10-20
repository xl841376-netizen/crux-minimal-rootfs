#!/bin/bash
# crux 刷入脚本
# 模式一（刷机包，在宿主/容器内执行）：自动识别 fastboot 与 mass(UMS) 设备，建分区，写系统与 ESP
# 模式二（已知分区）：直接对 --root / --esp 写入
set -euo pipefail

MODE="auto"
TAR=""; ROOTDEV=""; ESPDEV=""; EFI=""; KERNEL=""; DTB=""; INITRD=""
MU=""; LABEL="linux-root"; ROOT_SIZE="24G"; ESP_SIZE="512M"
MKFS=0; FLASH_MU=1; WAIT_SEC=180
ROOTMN=/mnt/cruxroot; ESPMN=/mnt/cruxesp

usage() {
  cat <<'EOM'
刷机包模式（自动识别设备并分区）:
  install-to-disk.sh --auto --tar <rootfs.tar.zst> --efi <BOOTAA64.EFI>
                     --kernel <Image> --dtb <dtb> [--initrd <initramfs.cpio.gz>]
                     [--mu <Mu-crux.img>] [--root-size 24G] [--esp-size 512M]
                     [--no-flash-mu] [--wait 180]

已知分区模式:
  install-to-disk.sh --root <分区> --esp <分区> --tar <rootfs.tar.zst>
                     --efi <BOOTAA64.EFI> --kernel <Image> --dtb <dtb>
                     [--initrd <initramfs.cpio.gz>] [--label linux-root] [--mkfs]

参数:
  --auto          自动识别 USB mass storage 盘，缺分区时自动创建
  --mu            Mu 固件镜像；存在 fastboot 设备时先 fastboot flash boot
  --no-flash-mu   跳过 fastboot 步骤
  --root-size     新建根分区大小，默认 24G
  --esp-size      新建 ESP 大小，默认 512M
  --wait          等待 USB 盘枚举的秒数，默认 180
EOM
}

while [ $# -gt 0 ]; do
  case "$1" in
    --auto) MODE="auto"; shift ;;
    --tar) TAR="$2"; shift 2 ;;
    --root) MODE="dev"; ROOTDEV="$2"; shift 2 ;;
    --esp) ESPDEV="$2"; shift 2 ;;
    --efi) EFI="$2"; shift 2 ;;
    --kernel) KERNEL="$2"; shift 2 ;;
    --dtb) DTB="$2"; shift 2 ;;
    --initrd) INITRD="$2"; shift 2 ;;
    --mu) MU="$2"; shift 2 ;;
    --no-flash-mu) FLASH_MU=0; shift ;;
    --label) LABEL="$2"; shift 2 ;;
    --root-size) ROOT_SIZE="$2"; shift 2 ;;
    --esp-size) ESP_SIZE="$2"; shift 2 ;;
    --wait) WAIT_SEC="$2"; shift 2 ;;
    --mkfs) MKFS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

for v in TAR EFI KERNEL DTB; do
  [ -n "${!v}" ] || { echo "缺少参数: $v"; usage; exit 1; }
done
for f in "$TAR" "$EFI" "$KERNEL" "$DTB"; do
  [ -f "$f" ] || { echo "文件不存在: $f"; exit 1; }
done
if [ -n "$INITRD" ] && [ ! -f "$INITRD" ]; then echo "文件不存在: $INITRD"; exit 1; fi
if [ -n "$MU" ] && [ ! -f "$MU" ]; then echo "文件不存在: $MU"; exit 1; fi
[ "$(id -u)" = "0" ] || { echo "需要 root 权限"; exit 1; }

cleanup() {
  umount "$ROOTMN" 2>/dev/null || true
  umount "$ESPMN" 2>/dev/null || true
}
trap cleanup EXIT

# 建块设备节点（容器内 /dev 常缺节点，maj:min 从 sysfs 取）
mknode() {
  local name="$1"
  local dev
  dev="$(cat "/sys/class/block/$name/dev" 2>/dev/null)" || return 1
  [ -b "/dev/$name" ] || mknod -m 660 "/dev/$name" b "${dev%%:*}" "${dev##*:}"
  [ -b "/dev/$name" ]
}

# 找一个 USB 附着的 sd 盘（排除宿主自身盘）
find_usb_disk() {
  local d name real
  for d in /sys/class/block/sd*; do
    name="$(basename "$d")"
    case "$name" in sd[a-z]) ;; *) continue ;; esac
    [ -e "$d/partition" ] && continue
    real="$(readlink -f "$d/device" 2>/dev/null || true)"
    case "$real" in *usb*) echo "$name"; return 0 ;; esac
  done
  return 1
}

# 按 PARTLABEL 找分区名
find_part() {
  local disk="$1" label="$2" p
  for p in /sys/class/block/"$disk"/"$disk"*; do
    [ -e "$p/partition" ] || continue
    if grep -q "PARTNAME=$label" "$p/uevent" 2>/dev/null; then
      basename "$p"
      return 0
    fi
  done
  return 1
}

# 1. fastboot 刷 Mu
if [ "$MODE" = "auto" ] && [ "$FLASH_MU" = "1" ] && [ -n "$MU" ]; then
  if fastboot devices 2>/dev/null | grep -q .; then
    echo "== fastboot flash boot $MU"
    fastboot flash boot "$MU"
  else
    echo "== 未检测到 fastboot 设备，跳过 Mu 刷入"
  fi
fi

# 2. 定位 USB 盘
if [ "$MODE" = "auto" ]; then
  echo "== 等待 USB mass storage 枚举（最多 ${WAIT_SEC}s）"
  DISK=""
  end=$(( $(date +%s) + WAIT_SEC ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if DISK="$(find_usb_disk)"; then break; fi
    DISK=""
    sleep 3
  done
  [ -n "$DISK" ] || { echo "未找到 USB 盘，确认设备处于 mass 模式后重试"; exit 1; }
  echo "== 目标盘 /dev/$DISK ($(cat /sys/class/block/$DISK/size) 扇区)"
  mknode "$DISK" || { echo "无法创建 /dev/$DISK"; exit 1; }

  # 3. 缺分区则创建
  ESPNAME="$(find_part "$DISK" efi || true)"
  ROOTNAME="$(find_part "$DISK" "$LABEL" || true)"

  if [ -z "$ESPNAME" ]; then
    echo "== 创建 ESP ($ESP_SIZE, PARTLABEL=efi)"
    sgdisk --new=0:0:+"$ESP_SIZE" --typecode=0:ef00 --change-name=0:efi "/dev/$DISK"
  fi
  if [ -z "$ROOTNAME" ]; then
    echo "== 创建根分区 ($ROOT_SIZE, PARTLABEL=$LABEL)"
    sgdisk --new=0:0:+"$ROOT_SIZE" --typecode=0:8300 --change-name=0:"$LABEL" "/dev/$DISK"
  fi

  if [ -z "$ESPNAME" ] || [ -z "$ROOTNAME" ]; then
    partprobe "/dev/$DISK" 2>/dev/null || true
    sleep 3
    ESPNAME="$(find_part "$DISK" efi || true)"
    ROOTNAME="$(find_part "$DISK" "$LABEL" || true)"
  fi
  [ -n "$ESPNAME" ] && [ -n "$ROOTNAME" ] || {
    echo "分区表已写入但内核未重新枚举；退出 mass 后重新进入再执行一次"; exit 1; }

  mknode "$ESPNAME" || { echo "无法创建 /dev/$ESPNAME"; exit 1; }
  mknode "$ROOTNAME" || { echo "无法创建 /dev/$ROOTNAME"; exit 1; }
  ESPDEV="/dev/$ESPNAME"
  ROOTDEV="/dev/$ROOTNAME"
  echo "== ESP $ESPDEV  根分区 $ROOTDEV"

  # 新分区格式化
  if ! blkid -s TYPE -o value "$ESPDEV" >/dev/null 2>&1; then
    echo "== 格式化 ESP (vfat)"
    mkfs.vfat -F32 -n EFI "$ESPDEV"
  fi
  if ! blkid -s TYPE -o value "$ROOTDEV" >/dev/null 2>&1 || [ "$MKFS" = "1" ]; then
    echo "== 格式化根分区 (ext4, 标签 $LABEL)"
    mkfs.ext4 -F -L "$LABEL" "$ROOTDEV"
  fi
else
  [ -n "$ROOTDEV" ] && [ -n "$ESPDEV" ] || { echo "缺少 --root / --esp"; exit 1; }
  [ -b "$ROOTDEV" ] && [ -b "$ESPDEV" ] || { echo "不是块设备"; exit 1; }
  if [ "$MKFS" = "1" ]; then
    echo "== 格式化根分区 (ext4, 标签 $LABEL)"
    mkfs.ext4 -F -L "$LABEL" "$ROOTDEV"
  fi
fi

# 4. 分区表重新读取后确认大小
echo "== 分区:"
lsblk -b -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$ROOTDEV" "$ESPDEV" 2>/dev/null || true

# 5. 写 rootfs
mkdir -p "$ROOTMN" "$ESPMN"
mount "$ROOTDEV" "$ROOTMN"
mount "$ESPDEV" "$ESPMN"

echo "== 解压 rootfs 到根分区"
tar --zstd -xpf "$TAR" -C "$ROOTMN"

ROOTUUID="$(blkid -s UUID -o value "$ROOTDEV")"
PARTLABEL="$(blkid -s PARTLABEL -o value "$ROOTDEV" || true)"
echo "== fstab"
if [ "$PARTLABEL" != "$LABEL" ]; then
  sed -i "s|^PARTLABEL=$LABEL|UUID=$ROOTUUID|" "$ROOTMN/etc/fstab"
fi
grep -E '^[^#]+[[:space:]]/[[:space:]]' "$ROOTMN/etc/fstab" || true

# 6. ESP 文件
echo "== 写 ESP"
mkdir -p "$ESPMN/EFI/BOOT" "$ESPMN/EFI/crux"
cp -f "$EFI" "$ESPMN/EFI/BOOT/BOOTAA64.EFI"
cp -f "$KERNEL" "$ESPMN/EFI/crux/Image"
DTBNAME="$(basename "$DTB")"
cp -f "$DTB" "$ESPMN/EFI/crux/$DTBNAME"
INITRDNAME=""
if [ -n "$INITRD" ]; then
  cp -f "$INITRD" "$ESPMN/EFI/crux/$(basename "$INITRD")"
  INITRDNAME="$(basename "$INITRD")"
fi

echo "== 生成 grub.cfg"
{
  echo "set timeout=5"
  echo "set default=0"
  echo ""
  echo "menuentry \"crux Linux\" {"
  echo "    search --no-floppy --file --set=root /EFI/crux/Image"
  echo "    insmod cruxdisplay"
  echo "    crux_display_init (\$root)/EFI/crux/$DTBNAME"
  echo "    linux (\$root)/EFI/crux/Image rw cfg80211.ieee80211_regdom=CN clk_ignore_unused pd_ignore_unused deferred_probe_timeout=-1 root=UUID=$ROOTUUID rootwait loglevel=5 vt.global_cursor_default=0 console=tty0"
  if [ -n "$INITRDNAME" ]; then
    echo "    initrd (\$root)/EFI/crux/$INITRDNAME"
  fi
  echo "    devicetree (\$root)/EFI/crux/$DTBNAME"
  echo "}"
} > "$ESPMN/EFI/crux/grub.cfg"

sync
echo "== 写入完成"
echo "根分区 $ROOTDEV  UUID=$ROOTUUID  PARTLABEL=${PARTLABEL:-无}"
ls -l "$ESPMN/EFI/BOOT" "$ESPMN/EFI/crux"
echo "退出 mass 模式，重启后 Mu 加载 EFI/BOOT/BOOTAA64.EFI"
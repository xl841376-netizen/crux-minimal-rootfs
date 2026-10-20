#!/bin/bash
# crux 写入脚本：rootfs 写分区 + ESP 文件 + 生成 grub 菜单
set -euo pipefail

TAR=""; ROOTDEV=""; ESPDEV=""; EFI=""; KERNEL=""; DTB=""; INITRD=""
LABEL="linux-root"; MKFS=0; ROOTMN=/mnt/cruxroot; ESPMN=/mnt/cruxesp

usage() {
  cat <<'EOM'
用法: install-to-disk.sh --tar <rootfs.tar.zst> --root <分区> --esp <分区>
                         --efi <BOOTAA64.EFI> --kernel <Image>
                         --dtb <dtb> [--initrd <initramfs.cpio.gz>]
                         [--label linux-root] [--mkfs]

  --tar      rootfs 包（Release 的 crux-rootfs-*.tar.zst）
  --root     根分区设备，例如 /dev/sda36
  --esp      ESP 分区设备，例如 /dev/sda35
  --efi      BOOTAA64.EFI 路径
  --kernel   内核 Image 路径
  --dtb      设备树路径
  --initrd   initramfs 路径
  --label    根分区标签，默认 linux-root
  --mkfs     写入前格式化根分区为 ext4
EOM
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tar) TAR="$2"; shift 2 ;;
    --root) ROOTDEV="$2"; shift 2 ;;
    --esp) ESPDEV="$2"; shift 2 ;;
    --efi) EFI="$2"; shift 2 ;;
    --kernel) KERNEL="$2"; shift 2 ;;
    --dtb) DTB="$2"; shift 2 ;;
    --initrd) INITRD="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --mkfs) MKFS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

for v in TAR ROOTDEV ESPDEV EFI KERNEL DTB; do
  [ -n "${!v}" ] || { echo "缺少参数: $v"; usage; exit 1; }
done
for f in "$TAR" "$EFI" "$KERNEL" "$DTB"; do
  [ -f "$f" ] || { echo "文件不存在: $f"; exit 1; }
done
if [ -n "$INITRD" ] && [ ! -f "$INITRD" ]; then echo "文件不存在: $INITRD"; exit 1; fi
[ -b "$ROOTDEV" ] || { echo "不是块设备: $ROOTDEV"; exit 1; }
[ -b "$ESPDEV" ] || { echo "不是块设备: $ESPDEV"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "需要 root 权限"; exit 1; }

cleanup() {
  umount "$ROOTMN" 2>/dev/null || true
  umount "$ESPMN" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$MKFS" = "1" ]; then
  echo "== 格式化 $ROOTDEV (ext4, 标签 $LABEL)"
  mkfs.ext4 -F -L "$LABEL" "$ROOTDEV"
fi

mkdir -p "$ROOTMN" "$ESPMN"
mount "$ROOTDEV" "$ROOTMN"
mount "$ESPDEV" "$ESPMN"

echo "== 写入 rootfs"
tar --zstd -xpf "$TAR" -C "$ROOTMN"

ROOTUUID="$(blkid -s UUID -o value "$ROOTDEV")"
PARTLABEL="$(blkid -s PARTLABEL -o value "$ROOTDEV" || true)"

echo "== 校验 fstab"
if [ "$PARTLABEL" != "$LABEL" ]; then
  sed -i "s|^PARTLABEL=$LABEL|UUID=$ROOTUUID|" "$ROOTMN/etc/fstab"
fi
grep -E '^[^#]+[[:space:]]/[[:space:]]' "$ROOTMN/etc/fstab" || true

echo "== 放 ESP 文件"
mkdir -p "$ESPMN/EFI/BOOT" "$ESPMN/EFI/crux"
cp -f "$EFI" "$ESPMN/EFI/BOOT/BOOTAA64.EFI"
cp -f "$KERNEL" "$ESPMN/EFI/crux/Image"
cp -f "$DTB" "$ESPMN/EFI/crux/$(basename "$DTB")"
DTBNAME="$(basename "$DTB")"
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
echo "== 结果"
echo "根分区 $ROOTDEV  UUID=$ROOTUUID  PARTLABEL=${PARTLABEL:-无}"
ls -l "$ESPMN/EFI/BOOT" "$ESPMN/EFI/crux"
echo "菜单 $ESPMN/EFI/crux/grub.cfg"
echo "完成，重启后 Mu 加载 EFI/BOOT/BOOTAA64.EFI"
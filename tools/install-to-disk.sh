#!/bin/bash
# crux 刷入脚本
# 模式一（刷机包，在宿主/容器内执行）：自动识别 fastboot 与 mass(UMS) 设备，建分区，写系统与 ESP
# 模式二（已知分区）：直接对 --root / --esp 写入
set -euo pipefail

MODE="auto"
TAR=""; ROOTDEV=""; ESPDEV=""; EFI=""; KERNEL=""; DTB=""; INITRD=""
MU=""; LABEL="linux-root"; ROOT_SIZE="24G"; ESP_SIZE="512M"
MKFS=0; FLASH_MU=1; WAIT_SEC=180; DISK_ARG=""
FROM_USERDATA=""; APPLY=0; DRY_RUN=0; DO_REBOOT=1
FROM_USERDATA=""; APPLY=0; DRY_RUN=0; DO_REBOOT=1
ROOTMN=/mnt/cruxroot; ESPMN=/mnt/cruxesp

usage() {
  cat <<'EOM'
刷机包模式（自动识别设备并分区）:
  install-to-disk.sh --auto --tar <rootfs.tar.zst> --efi <BOOTAA64.EFI>
                     --kernel <Image> --dtb <dtb> [--initrd <initramfs.cpio.gz>]
                     [--mu <Mu-crux.img>] [--root-size 24G|rest] [--esp-size 512M|128M]
                     [--no-flash-mu] [--wait 180]

已知分区模式:
  install-to-disk.sh --root <分区> --esp <分区> --tar <rootfs.tar.zst>
                     --efi <BOOTAA64.EFI> --kernel <Image> --dtb <dtb>
                     [--initrd <initramfs.cpio.gz>] [--label linux-root] [--mkfs]

参数:
  --auto          自动识别 USB mass storage 盘，缺分区时自动创建
  --mu            Mu 固件镜像；存在 fastboot 设备时先 fastboot flash boot
  --no-flash-mu   跳过 fastboot 步骤
  --root-size     新建根分区大小：24G / 40G / 80000M 任意填写，或 rest 占满剩余空间，默认 24G
  --esp-size      新建 ESP 大小：128M / 512M / 自定义，默认 512M
  --wait          等待 USB 盘枚举的秒数，默认 180
  --disk          指定盘（如 /dev/loop48），跳过 USB 识别
  --from-userdata 从 userdata 尾部释放空间，例 40G（盘上无其他空闲时使用）
  --apply         真正执行 userdata 缩容（不带则只打印计划）
  --no-reboot     刷完 Mu 不自动重启
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
    --disk) DISK_ARG="$2"; shift 2 ;;
    --from-userdata) FROM_USERDATA="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --no-reboot) DO_REBOOT=0; shift ;;
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

size_ok() {
  case "$1" in
    rest|REST|all|ALL) return 0 ;;
    [0-9]*[MGmg]) return 0 ;;
    *) return 1 ;;
  esac
}
size_ok "$ESP_SIZE" || { echo "ESP 大小格式无效: $ESP_SIZE（例 128M / 512M / 1G）"; exit 1; }
size_ok "$ROOT_SIZE" || { echo "根分区大小格式无效: $ROOT_SIZE（例 24G / 40G / rest）"; exit 1; }
if [ -n "$FROM_USERDATA" ]; then
  size_ok "$FROM_USERDATA" || { echo "释放量格式无效: $FROM_USERDATA（例 40G / 30000M）"; exit 1; }
fi
if [ -n "$FROM_USERDATA" ]; then
  size_ok "$FROM_USERDATA" || { echo "释放量格式无效: $FROM_USERDATA（例 40G / 30000M）"; exit 1; }
fi

size_mb() {
  local v="$1"
  case "$v" in
    *[Mm]) echo "${v%[Mm]}" ;;
    *[Gg]) echo "$(( ${v%[Gg]} * 1024 ))" ;;
    *) echo 0 ;;
  esac
}
ESP_MB="$(size_mb "$ESP_SIZE")"
[ "$ESP_MB" -ge 128 ] 2>/dev/null || echo "提示: ESP $ESP_SIZE 偏小，引导件约需 80M，建议 128M 或 512M"
ROOT_MB="$(size_mb "$ROOT_SIZE")"
[ "$ROOT_MB" -ge 6144 ] 2>/dev/null || [ "$ROOT_MB" = "0" ] || echo "提示: 根分区 $ROOT_SIZE 小于 6G，解压后系统约需 6G"
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
# Mu 的 mass 盘标识：VID:PID 05c6:f000 / Product "USB MASS STORAGE"
#                   SCSI vendor Qualcomm / model "MMC Storage"，约 476GiB
find_usb_disk() {
  local d name real vendor model fallback=""
  for d in /sys/class/block/sd*; do
    name="$(basename "$d")"
    case "$name" in sd[a-z]) ;; *) continue ;; esac
    [ -e "$d/partition" ] && continue
    real="$(readlink -f "$d/device" 2>/dev/null || true)"
    case "$real" in *usb*) ;; *) continue ;; esac
    vendor="$(cat "/sys/block/$name/device/vendor" 2>/dev/null | tr -d ' ')"
    model="$(cat "/sys/block/$name/device/model" 2>/dev/null | tr -d ' ')"
    case "${vendor}${model}" in
      *Qualcomm*MMC*|*MMCStorage*)
        echo "$name"
        return 0 ;;
    esac
    [ -z "$fallback" ] && fallback="$name"
  done
  if [ -n "$fallback" ]; then
    echo "$fallback"
    return 0
  fi
  return 1
}

# 打印候选 USB 盘信息（识别失败时用于诊断）
list_usb_disks() {
  local d name real vendor model
  for d in /sys/class/block/sd*; do
    name="$(basename "$d")"
    case "$name" in sd[a-z]) ;; *) continue ;; esac
    [ -e "$d/partition" ] && continue
    real="$(readlink -f "$d/device" 2>/dev/null || true)"
    case "$real" in *usb*) ;; *) continue ;; esac
    vendor="$(cat "/sys/block/$name/device/vendor" 2>/dev/null | tr -s ' ')"
    model="$(cat "/sys/block/$name/device/model" 2>/dev/null | tr -s ' ')"
    echo "   /dev/$name  vendor=[$vendor] model=[$model]  $(( $(cat /sys/class/block/$name/size) / 2097152 ))GiB"
  done
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

# 从 userdata 尾部释放空间（resize2fs 缩文件系统 → 改小分区 → 留出空隙）
# 参数：$1=盘名 $2=释放量 返回：FREED_START/FREED_END（可用扇区范围）
shrink_userdata() {
  local disk="$1" release="$2" udname udnum uddev start end rel_sec new_end fs_k new_mb minsz
  udname="$(find_part "$disk" userdata || true)"
  [ -n "$udname" ] || { echo "未找到 PARTLABEL=userdata"; return 1; }
  udnum="${udname#"$disk"}"
  udnum="${udnum#p}"
  mknode "$udname" || { echo "无法创建 /dev/$udname"; return 1; }
  uddev="/dev/$udname"

  if findmnt -no SOURCE "$uddev" >/dev/null 2>&1; then
    echo "userdata 正在挂载，缩容前需先卸载"; return 1
  fi

  start="$(sgdisk -i "$udnum" "/dev/$disk" | awk '/First sector/{print $3}')"
  end="$(sgdisk -i "$udnum" "/dev/$disk" | awk '/Last sector/{print $3}')"
  [ -n "$start" ] && [ -n "$end" ] || { echo "读取 userdata 分区范围失败"; return 1; }

  case "$release" in
    *[Mm]) rel_sec=$(( ${release%[Mm]} * 2048 )) ;;
    *[Gg]) rel_sec=$(( ${release%[Gg]} * 2097152 )) ;;
    *) echo "释放量单位需为 M 或 G"; return 1 ;;
  esac
  new_end=$(( end - rel_sec ))
  if [ "$new_end" -le "$start" ]; then echo "释放量超过 userdata 大小"; return 1; fi
  fs_k=$(( (new_end - start + 1) * 512 / 1024 ))

  echo "== userdata 现状: 分区 $start-$end（$(( (end-start+1)/2097152 ))GiB）"
  echo "== 计划: 缩到 $start-$new_end（约 $(( fs_k / 1048576 ))GiB），释放 ${release}"
  echo "   resize2fs $uddev $(( fs_k / 1024 ))M"
  echo "   sgdisk --delete=$udnum /dev/$disk"
  echo "   sgdisk --new=$udnum:$start:$new_end --typecode=$udnum:A03A --change-name=$udnum:userdata /dev/$disk"

  if [ "$APPLY" != "1" ]; then
    echo "== 未加 --apply，仅打印计划"
    DRY_RUN=1
  else
    local bk="/root/gpt-backup-$(basename "$disk")-$(date +%Y%m%d-%H%M%S).bin"
    sgdisk --backup="$bk" "/dev/$disk" >/dev/null
    echo "== GPT 已备份: $bk"
    e2fsck -fp "$uddev" || true
    resize2fs "$uddev" "$(( fs_k / 1024 ))M"
    sgdisk --delete="$udnum" "/dev/$disk"
    sgdisk --new="$udnum:$start:$new_end" --typecode="$udnum:A03A"            --change-name="$udnum:userdata" "/dev/$disk"
    partprobe "/dev/$disk" 2>/dev/null || true
    sleep 2
    echo "== userdata 缩容完成"
  fi

  FREED_START=$(( new_end + 1 ))
  FREED_END="$end"
  return 0
}

# 1. fastboot 阶段：刷 Mu 固件 → 重启 → 进 Mu 界面切 mass
if [ "$MODE" = "auto" ] && [ "$FLASH_MU" = "1" ] && [ -n "$MU" ]; then
  if fastboot devices 2>/dev/null | grep -q .; then
    echo "== 阶段 1/3 fastboot：flash boot $MU"
    fastboot flash boot "$MU"
    if [ "$DO_REBOOT" = "1" ]; then
      echo "== fastboot reboot"
      fastboot reboot || true
      echo "== 等待 fastboot 设备退出"
      for _ in $(seq 1 30); do
        fastboot devices 2>/dev/null | grep -q . || break
        sleep 2
      done
      echo "== 设备重启进入 Mu；在 Mu 界面选择 mass storage（USB 大容量存储）"
    else
      echo "== 已刷入，未重启（--no-reboot）"
    fi
  else
    echo "== 阶段 1/3 fastboot：未检测到 fastboot 设备，跳过 Mu 刷入"
  fi
else
  echo "== 阶段 1/3 fastboot：跳过（未提供 --mu 或已禁用）"
fi

# 2. 定位 USB 盘
if [ "$MODE" = "auto" ]; then
  if [ -n "$DISK_ARG" ]; then
    DISK="$(basename "$DISK_ARG")"
    [ -b "/dev/$DISK" ] || mknod -m 660 "/dev/$DISK" b "$(cat /sys/class/block/$DISK/dev | cut -d: -f1)" "$(cat /sys/class/block/$DISK/dev | cut -d: -f2)"
  else
    echo "== 阶段 2/3 等待 USB mass storage 枚举（最多 ${WAIT_SEC}s）"
    DISK=""
    end=$(( $(date +%s) + WAIT_SEC ))
    tick=0
    while [ "$(date +%s)" -lt "$end" ]; do
      if DISK="$(find_usb_disk)"; then break; fi
      DISK=""
      tick=$(( tick + 1 ))
      [ $(( tick % 5 )) -eq 0 ] && echo "   等待中（$(( end - $(date +%s) ))s 剩余）"
      sleep 3
    done
    if [ -z "$DISK" ]; then
      echo "未找到 USB 盘：确认设备已进 Mu 并选择 mass storage，或用 --wait 延长等待"
      echo "当前可见的 USB 块设备（应为 Qualcomm / MMC Storage, 约 476GiB）:"
      list_usb_disks
      echo "USB 设备列表（mass 应为 05c6:f000）:"
      lsusb 2>/dev/null | grep -E '05c6|Mass|Storage' || echo "   （无匹配）"
      exit 1
    fi
  fi
  BLOCKS="$(cat /sys/class/block/$DISK/size)"
  echo "== 目标盘 /dev/$DISK 容量 $(( BLOCKS / 2097152 ))GiB（$BLOCKS 扇区）"
  echo "   标识 vendor=[$(cat "/sys/block/$DISK/device/vendor" 2>/dev/null | tr -s ' ')] model=[$(cat "/sys/block/$DISK/device/model" 2>/dev/null | tr -s ' ')]"
  echo "== ESP=$ESP_SIZE  根分区=$ROOT_SIZE"
  mknode "$DISK" || { echo "无法创建 /dev/$DISK"; exit 1; }

  echo "== 阶段 3/3 分区与写入"

  # 空间来源：盘上无空闲时从 userdata 尾部切
  ESPNAME="$(find_part "$DISK" efi || true)"
  ROOTNAME="$(find_part "$DISK" "$LABEL" || true)"
  FREESTART=""; FREEEND=""

  if [ -z "$ESPNAME" ] || [ -z "$ROOTNAME" ]; then
    FREE_TXT="$(sgdisk -p "/dev/$DISK" | grep -E '^Total free space')"
    echo "== $FREE_TXT"
    if [ -n "$FROM_USERDATA" ]; then
      shrink_userdata "$DISK" "$FROM_USERDATA" || exit 1
      if [ "$DRY_RUN" = "1" ]; then
        echo "== 分区表未改动；确认后加 --apply 执行"
        exit 0
      fi
      FREESTART="$FREED_START"; FREEEND="$FREED_END"
      echo "== userdata 之后可用扇区: $FREESTART-$FREEEND"
    fi

    mkpart() { # $1=分区号或0 $2=起点扇区或0 $3=终点规格 $4=类型码 $5=名称
      sgdisk --new="$1:$2:$3" --typecode="$1:$4" --change-name="$1:$5" "/dev/$DISK"
    }

    if [ -z "$ESPNAME" ]; then
      echo "== 创建 ESP ($ESP_SIZE, PARTLABEL=efi)"
      if [ -n "$FREESTART" ]; then
        mkpart 0 "$FREESTART" "+$ESP_SIZE" ef00 efi
        FREESTART=$(( $(sgdisk -i "$(sgdisk -p "/dev/$DISK" | awk '/efi$/{print $1}' | tail -1)" "/dev/$DISK" | awk '/Last sector/{print $3}') + 1 ))
      else
        mkpart 0 0 "+$ESP_SIZE" ef00 efi
      fi
    fi
    if [ -z "$ROOTNAME" ]; then
      case "$ROOT_SIZE" in
        rest|REST|all|ALL)
          if [ -n "$FREEEND" ]; then
            echo "== 创建根分区（占满 userdata 释放的空间, PARTLABEL=$LABEL）"
            mkpart 0 "$FREESTART" "$FREEEND" 8300 "$LABEL"
          else
            echo "== 创建根分区（占满剩余空间, PARTLABEL=$LABEL）"
            mkpart 0 0 0 8300 "$LABEL"
          fi ;;
        *)
          echo "== 创建根分区 ($ROOT_SIZE, PARTLABEL=$LABEL)"
          if [ -n "$FREESTART" ]; then
            mkpart 0 "$FREESTART" "+$ROOT_SIZE" 8300 "$LABEL"
          else
            mkpart 0 0 "+$ROOT_SIZE" 8300 "$LABEL"
          fi ;;
      esac
    fi
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

  # 新分区格式化（blkid 对空分区可能返回空串而非非零，按字符串判空）
  ESPTYPE="$(blkid -s TYPE -o value "$ESPDEV" 2>/dev/null || true)"
  ROOTTYPE="$(blkid -s TYPE -o value "$ROOTDEV" 2>/dev/null || true)"
  if [ -z "$ESPTYPE" ]; then
    echo "== 格式化 ESP (vfat)"
    mkfs.vfat -F32 -n EFI "$ESPDEV"
  else
    echo "== ESP 已有文件系统: $ESPTYPE（保留）"
  fi
  if [ -z "$ROOTTYPE" ] || [ "$MKFS" = "1" ] || [ "$ROOTTYPE" != "ext4" ]; then
    echo "== 格式化根分区 (ext4, 标签 $LABEL)"
    mkfs.ext4 -F -L "$LABEL" "$ROOTDEV"
  else
    echo "== 根分区已有 ext4（保留，--mkfs 可强制重格式化）"
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
if [ -f "$ESPMN/EFI/crux/grub.cfg" ]; then
  BK="$ESPMN/EFI/crux/grub.cfg.bak-$(date +%Y%m%d-%H%M%S)"
  cp -f "$ESPMN/EFI/crux/grub.cfg" "$BK"
  echo "   已有菜单已备份: $(basename "$BK")"
fi
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
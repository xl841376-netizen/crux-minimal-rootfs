#!/bin/bash
# crux: mount the modem (NON-HLOS) partition read-only for tqftpserv.
# Supplies image/modem_pr -> mcfg catalog + subsystem images.
# Partlabel is matched dynamically; no device name is hardcoded.
MNT=/mnt/mdmpart

mkdir -p "$MNT"

# already mounted? nothing to do
if mountpoint -q "$MNT"; then
	echo "[crux] $MNT already mounted"
	exit 0
fi

DEV=""
for p in /dev/disk/by-partlabel/modem /dev/disk/by-partlabel/modem_a /dev/disk/by-partlabel/modem_b; do
	[ -e "$p" ] || continue
	DEV="$p"
	break
done

if [ -z "$DEV" ]; then
	# fallback: scan block devices for the partlabel via sysfs
	for u in /sys/class/block/sd*/uevent; do
		[ -e "$u" ] || continue
		pn=$(grep -s PARTNAME "$u" | cut -d= -f2)
		case "$pn" in
		modem)
			DEV="/dev/$(basename "$(dirname "$u")")"
			break
			;;
		esac
	done
fi

if [ -z "$DEV" ]; then
	echo "[crux] modem partition not found" >&2
	exit 1
fi

echo "[crux] modem partition: $DEV -> $MNT"
mount -t vfat -o ro "$DEV" "$MNT" || exit 1

# publish image/modem_pr next to the firmware the loader looks at
for d in /lib/firmware/qcom/sm8150/xiaomi/crux /usr/lib/firmware/qcom/sm8150/xiaomi/crux; do
	[ -d "$d" ] || continue
	ln -sfn "$MNT/image/modem_pr" "$d/modem_pr"
	echo "[crux] linked $d/modem_pr -> $MNT/image/modem_pr"
done

exit 0

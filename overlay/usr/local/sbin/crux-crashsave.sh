#!/bin/bash
# Save previous boot's dmesg tail onto the ESP (FAT) so it can be read from a
# PC/phone over mass-storage, without depending on a readable console.
set -u
EFI=/dev/disk/by-partlabel/efi
MNT=/mnt/efi-crash
LOG=/var/log/dmesg-snap.prev.txt
OK=/var/lib/crux/lastboot.ok
owned=0

# reuse an existing mount of the ESP if there is one
T=$(findmnt -no TARGET -S "$EFI" 2>/dev/null | head -1)
if [ -n "${T:-}" ]; then
  MNT=$T
else
  mkdir -p $MNT
  mount -o umask=0022 "$EFI" $MNT || exit 0
  owned=1
fi
OUT=$MNT/EFI/crux
mkdir -p "$OUT"

if [ -f "$LOG" ]; then
  tail -n 600 "$LOG" > "$OUT/LASTBOOT.TXT"
  if [ ! -f "$OK" ]; then
    { echo "# previous boot did not shut down cleanly";
      echo "# captured: $(date -Is)";
      tail -n 600 "$LOG"; } > "$OUT/CRASH.TXT"
  fi
fi
sync
rm -f "$OK"
[ $owned -eq 1 ] && umount $MNT
exit 0

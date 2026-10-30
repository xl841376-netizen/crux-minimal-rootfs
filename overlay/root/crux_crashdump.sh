#!/bin/sh
# crux: 开机自动提取上一次崩溃日志（ramoops record 区 -> 明文 dmesg）
# 依赖: /root/rexport.ko（把 record 区裸读到 /tmp/rec.bin）
set -u

BIN=/tmp/rec.bin
OUT=/var/log/last-crash.log

modprobe rexport 2>/dev/null || insmod /root/rexport.ko 2>/dev/null
[ -f "$BIN" ] || exit 0

# record 区是否真的有内容：找 pstore record 头 "==="
if ! head -c 4096 "$BIN" | grep -qa '==='; then
	rm -f "$BIN"
	exit 0
fi

# 跳过 persistent_ram 12 字节头，取 256KB，去掉不可打印字符
dd if="$BIN" bs=1 skip=12 count=263168 2>/dev/null \
	| LC_ALL=C tr -cd '\11\12\15\40-\176' > "$OUT.tmp" 2>/dev/null
rm -f "$BIN"

# 必须是真崩溃
if ! grep -qaE 'Panic|Oops|Unable to handle' "$OUT.tmp"; then
	rm -f "$OUT.tmp"
	exit 0
fi

# 与上次内容相同就不覆盖
if [ -f "$OUT" ] && [ "$(md5sum < "$OUT.tmp" | cut -d' ' -f1)" = "$(md5sum < "$OUT" | cut -d' ' -f1)" ]; then
	rm -f "$OUT.tmp"
	exit 0
fi

mv "$OUT.tmp" "$OUT"
cp -a "$OUT" "/var/log/last-crash-$(date +%Y%m%d-%H%M%S).log" 2>/dev/null
logger -t crux-crashdump "saved /var/log/last-crash.log ($(wc -l < "$OUT") lines)"
exit 0
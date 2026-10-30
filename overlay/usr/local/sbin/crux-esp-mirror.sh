#!/bin/sh
# crux-esp-mirror —— 把"关键日志"以【追加】方式写到 ESP(FAT32)
#
# 设计原则（2026-10-30 用户要求）
#   1. 只追加，不覆盖：内容一路往后长，history 不丢。
#   2. 达到上限才清理：满了先归档成 .1 / .2，再从空开始追加，绝不 truncate 丢内容。
#   3. 明文：pstore 压缩已关，明文对单 bit 翻转是"局部坏一行"，
#      而压缩流对单 bit 翻转是"整段全废"。
#   4. 多副本冗余：同一段内核日志同时存在于
#        /var/log/crux-kmsg.log（设备上，滚动）
#        /var/log/dmesg-snap.txt（快照）
#        ESP KEY.TXT / TAIL.TXT（跨复位，追加累积）
#        ESP KEY.PREV.TXT / TAIL.PREV.TXT（上一次启动的死前现场）
#      任意一份被 DDR/FAT 翻转破坏，其他副本仍能看到同一条事件。
#
# ESP 上的布局：
#   KEY.TXT        关键日志块（distil.awk 提炼），上限 KEY_MAX
#   KEY.1.TXT..    归档（最多 ARCHIVE 份）
#   KEY.PREV.TXT   上一次启动的死前现场（内容级印记，只会被轮转一次）
#   TAIL.TXT       原始内核日志增量，上限 TAIL_MAX
#   TAIL.1.TXT..   归档
#   TAIL.PREV.TXT  上一次启动的死前现场
#   SNAP.TXT       dmesg 快照累积
#   .state         增量游标（inode + offset），持久化，重启后接着追加
#
# 安全：只写上述文件与 *.tmp，原子 mv，绝不碰 Image87/dtb/grub.cfg。

set -u

PART=/dev/disk/by-partlabel/efi
FALLBACK=/mnt/efi-mirror
KMSG=/var/log/crux-kmsg.log
SNAP=/var/log/dmesg-snap.txt
AWK=/usr/local/lib/crux/distil.awk
REL=EFI/crux
INT=5

KEY_MAX=524288          # 512 KB
TAIL_MAX=16777216       # 16 MB
SNAP_KEEP=16384         # 16 KB
SNAP_MAX=4194304        # 4 MB
ARCHIVE=3               # 每个文件保留 3 份归档

STATE_DIR=/var/lib/crux
STATE=$STATE_DIR/esp-mirror.state
SNAP_MD5=$STATE_DIR/snap.md5
LOGCAP=$STATE_DIR/esp-mirror.log

mkdir -p "$STATE_DIR" 2>/dev/null

log() {
	printf '%s %s\n' "$(date -Is)" "$*" >> "$LOGCAP" 2>/dev/null
	sz=$(stat -c %s "$LOGCAP" 2>/dev/null || echo 0)
	if [ "$sz" -gt 262144 ]; then
		tail -c 131072 "$LOGCAP" > "$LOGCAP.t" 2>/dev/null && mv -f "$LOGCAP.t" "$LOGCAP"
	fi
}

# ---- 内容级印记轮转：只有头部时间戳早于本次开机(btime)才轮转 ----------------
rotate_stale() {
	d=$1
	BT=$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null)
	BT=${BT:-0}
	for n in KEY TAIL SNAP; do
		f="$d/$n.TXT"
		[ -s "$f" ] || continue
		ts=$(head -1 "$f" 2>/dev/null | grep -o '[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -1 | tr 'T' ' ')
		[ -n "${ts:-}" ] || continue
		ft=$(date -d "$ts" +%s 2>/dev/null) || continue
		if [ "$ft" -lt "$BT" ]; then
			cp -f "$f" "$d/$n.PREV.TXT" 2>/dev/null && \
				log "rotate-stale $n (hdr=$ts < boot)"
		fi
	done
	sync
}

# ---- 上限归档：满了把当前改名为 .1，旧的依次后移，最多 ARCHIVE 份 ----------
# 归档名用 TAIL.1.TXT（不是 TAIL.TXT.1），并立刻新建一个带时间戳头的空文件：
# rotate_stale() 靠第一行的时间戳判断"是不是上一次启动的"，新文件必须带头。
file_head() {
	printf '# %s %s uptime=%ss\n' "$1" "$(date -Is)" "$(cut -d. -f1 /proc/uptime)"
}

rotate_full() {
	f=$1
	base=${f%.TXT}
	tag=$(basename "$base" | tr 'A-Z' 'a-z')
	i=$ARCHIVE
	while [ "$i" -ge 2 ]; do
		prev=$((i - 1))
		[ -f "$base.$prev.TXT" ] && mv -f "$base.$prev.TXT" "$base.$i.TXT" 2>/dev/null
		i=$prev
	done
	if mv -f "$f" "$base.1.TXT" 2>/dev/null; then
		file_head "$tag" > "$f" 2>/dev/null
		log "rotate-full $(basename "$f") -> $(basename "$base").1.TXT (keep $ARCHIVE)"
	fi
	sync
}

# 启动时确保每个文件第一行是带日期的时间戳头（旧版遗留文件补一次）
fix_header() {
	f=$1
	tag=$2
	[ -f "$f" ] || { file_head "$tag" > "$f"; return 0; }
	[ -s "$f" ] || { file_head "$tag" > "$f"; return 0; }
	head -1 "$f" | grep -q '[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T' && return 0
	sed -i "1i # $tag $(date -Is) uptime=$(cut -d. -f1 /proc/uptime)" "$f" 2>/dev/null
	log "fix-header $tag"
}

append_limited() {
	dst=$1
	src=$2
	max=$3
	[ -s "$src" ] || return 0
	sz=$(stat -c %s "$dst" 2>/dev/null || echo 0)
	if [ "$sz" -ge "$max" ]; then
		rotate_full "$dst"
	fi
	cat "$src" >> "$dst" 2>/dev/null
}

# ---- 增量游标：inode + offset，持久化在 /var/lib/crux ----------------------
read_cursor() {
	ino=0
	off=0
	if [ -f "$STATE" ]; then
		read cino coff < "$STATE" 2>/dev/null || { cino=0; coff=0; }
		ino=${cino:-0}
		off=${coff:-0}
	fi
}

write_cursor() {
	printf '%s %s\n' "$1" "$2" > "$STATE" 2>/dev/null
}

FIRST=1

while :; do
	M=$(findmnt -no TARGET -S "$PART" 2>/dev/null | head -1)
	if [ -z "${M:-}" ]; then
		mkdir -p "$FALLBACK"
		if mount -o umask=0022 "$PART" "$FALLBACK" 2>/dev/null; then
			M=$FALLBACK
		else
			sleep $INT
			continue
		fi
	fi
	OUT="$M/$REL"
	if [ ! -d "$OUT" ]; then
		sleep $INT
		continue
	fi

	if [ "$FIRST" = 1 ]; then
		rotate_stale "$OUT"
		# 旧版遗留文件没有时间戳头 → 补一次，否则 rotate_stale 永远判不出新旧
		fix_header "$OUT/KEY.TXT" key
		fix_header "$OUT/TAIL.TXT" tail
		fix_header "$OUT/SNAP.TXT" snap
		FIRST=0
	fi

	# ---------------- 内核日志增量 ----------------
	if [ -s "$KMSG" ]; then
		cur_ino=$(stat -c %i "$KMSG" 2>/dev/null || echo 0)
		cur_sz=$(stat -c %s "$KMSG" 2>/dev/null || echo 0)

		# 本次启动第一次写：打一个可读时间戳头（rotate_stale 靠它判断新旧）
		if [ ! -s "$OUT/TAIL.TXT" ]; then
			printf '# tail %s uptime=%ss boot=%s\n' \
				"$(date -Is)" "$(cut -d. -f1 /proc/uptime)" \
				"$(date -d @"$(awk '/^btime/{print $2}' /proc/stat)" '+%F %T' 2>/dev/null)" \
				>> "$OUT/TAIL.TXT" 2>/dev/null
		fi

		read_cursor
		if [ "$cur_ino" != "$ino" ] || [ "$cur_sz" -lt "$off" ]; then
			# 源换了或被截短：从头开始（宁可重复，不能漏）
			off=0
		fi

		if [ "$cur_sz" -gt "$off" ]; then
			tail -c +$((off + 1)) "$KMSG" 2>/dev/null > "$OUT/K.inc.tmp"

			# 1) KEY：只对增量跑 distil.awk
			if [ -s "$OUT/K.inc.tmp" ] && [ -f "$AWK" ]; then
				awk -f "$AWK" "$OUT/K.inc.tmp" > "$OUT/K.out.tmp" 2>/dev/null
				if [ -s "$OUT/K.out.tmp" ]; then
					{
						printf '\n-- %s uptime=%ss --\n' \
							"$(date -Is)" "$(cut -d. -f1 /proc/uptime)"
						cat "$OUT/K.out.tmp"
					} > "$OUT/K.batch.tmp" 2>/dev/null
					append_limited "$OUT/KEY.TXT" "$OUT/K.batch.tmp" $KEY_MAX
					rm -f "$OUT/K.batch.tmp"
				fi
				rm -f "$OUT/K.out.tmp"
			fi

			# 2) TAIL：原始增量直接追加（去 NUL）
			if [ -s "$OUT/K.inc.tmp" ]; then
				tr -d '\000' < "$OUT/K.inc.tmp" > "$OUT/T.batch.tmp" 2>/dev/null
				append_limited "$OUT/TAIL.TXT" "$OUT/T.batch.tmp" $TAIL_MAX
				rm -f "$OUT/T.batch.tmp"
			fi
			rm -f "$OUT/K.inc.tmp"

			write_cursor "$cur_ino" "$cur_sz"
		fi
	fi

	# ---------------- dmesg 快照（变化才追加） ----------------
	if [ -s "$SNAP" ]; then
		newm=$(md5sum "$SNAP" 2>/dev/null | cut -d' ' -f1)
		oldm=$(cat "$SNAP_MD5" 2>/dev/null || true)
		if [ "$newm" != "$oldm" ]; then
			{
				printf '\n=== snap %s uptime=%ss ===\n' \
					"$(date -Is)" "$(cut -d. -f1 /proc/uptime)"
				tail -c $SNAP_KEEP "$SNAP" | tr -d '\000'
			} > "$OUT/S.batch.tmp" 2>/dev/null
			append_limited "$OUT/SNAP.TXT" "$OUT/S.batch.tmp" $SNAP_MAX
			rm -f "$OUT/S.batch.tmp"
			printf '%s\n' "$newm" > "$SNAP_MD5" 2>/dev/null
		fi
	fi

	sync
	sleep $INT
done
#!/bin/bash
# crux: 开机给 SMB5 充电器设一个合理的 ICHG（内核驱动默认沿用 bootloader 的 500mA）
# 注意：仅当 crux-charger 存在时生效；失败不影响开机。
set -u
PS=/sys/class/power_supply/crux-charger
LOG=/var/log/crux-charger-init.log
TARGET_UA=${1:-1500000}

for i in $(seq 1 60); do
	[ -e "$PS/constant_charge_current_max" ] && break
	sleep 1
done

if [ ! -e "$PS/constant_charge_current_max" ]; then
	echo "=== $(date '+%F %T') crux-charger 未注册，跳过 ===" >> $LOG
	exit 0
fi

cur=$(cat $PS/constant_charge_current_max 2>/dev/null)
echo "=== $(date '+%F %T') 当前 ICHG=$cur，目标 $TARGET_UA ===" >> $LOG

if [ "${cur:-0}" -lt "$TARGET_UA" ]; then
	if echo "$TARGET_UA" > $PS/constant_charge_current_max 2>>$LOG; then
		echo "ok: ICHG -> $(cat $PS/constant_charge_current_max)" >> $LOG
	else
		echo "fail: 写入被拒" >> $LOG
	fi
fi

echo "online=$(cat $PS/online 2>/dev/null) status=$(cat $PS/status 2>/dev/null)" >> $LOG
exit 0

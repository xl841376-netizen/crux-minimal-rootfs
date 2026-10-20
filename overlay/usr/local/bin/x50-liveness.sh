#!/bin/sh
# X50 存活监控：状态变化时记时间戳；掉线时把 dmesg 尾部抓下来，便于判断原因。
L=/var/log/x50-liveness.log
prev=""
while true; do
	if [ -e /dev/mhi_pipe_10 ]; then
		cur=UP
	elif [ -e /dev/mhi_pipe_2 ]; then
		cur=SBL
	elif [ -e /sys/bus/mhi/devices/mhi0_IP_HW_OFFLOAD_0 ]; then
		cur=MHI
	else
		cur=DOWN
	fi
	if [ "$cur" != "$prev" ]; then
		echo "$(date '+%F %T') $cur uptime=$(cut -d. -f1 /proc/uptime)s" >> $L
		if [ "$cur" = "DOWN" ]; then
			{
				echo "----- dmesg tail @ $(date '+%T') -----"
				dmesg | tail -30
				echo "----- end -----"
			} >> $L
		fi
		prev="$cur"
	fi
	sleep 2
done
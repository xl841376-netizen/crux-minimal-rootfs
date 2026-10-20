#!/bin/sh
# 记录 电池电压/电流/容量 + 模组状态 + 负载，2 秒一次，用于判断"挂机前是否有电压塌陷/电流激增"
OUT=/var/log/power-snap.txt
BAT=/sys/class/power_supply/bq27z561-0
while :; do
    {
        v=$(cat $BAT/voltage_now 2>/dev/null)
        i=$(cat $BAT/current_now 2>/dev/null)
        c=$(cat $BAT/capacity 2>/dev/null)
        st=$(cat $BAT/status 2>/dev/null)
        rp=""
        for r in /sys/class/remoteproc/remoteproc*; do
            [ -e "$r/name" ] || continue
            rp="$rp$(cat $r/name)=$(cat $r/state 2>/dev/null),"
        done
        printf '%s v=%s uV i=%s uA cap=%s%% %s rp=[%s] load=%s\n' \
            "$(date '+%H:%M:%S')" "${v:-na}" "${i:-na}" "${c:-na}" "${st:-na}" "$rp" "$(cut -d' ' -f1-3 /proc/loadavg)"
    } >> ${OUT}.tmp 2>/dev/null || true
    tail -n 300 ${OUT}.tmp > ${OUT}.tmp2 2>/dev/null && mv -f ${OUT}.tmp2 ${OUT}.tmp
    mv -f ${OUT}.tmp "$OUT" 2>/dev/null || true
    sleep 2
done

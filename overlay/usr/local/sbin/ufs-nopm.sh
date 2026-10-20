#!/bin/sh
D=/sys/devices/platform/soc@0/1d84000.ufshc
i=0
while [ $i -lt 50 ]; do
    [ -w "$D/rpm_lvl" ] && break
    sleep 0.2
    i=$((i+1))
done
echo 0 > "$D/rpm_lvl" 2>/dev/null || echo "rpm_lvl write failed"
echo 0 > "$D/clkgate_enable" 2>/dev/null || echo "clkgate write failed"
echo 0 > "$D/clkscale_enable" 2>/dev/null || echo "clkscale write failed"
echo "ufs-nopm: rpm_lvl=$(cat $D/rpm_lvl) clkgate=$(cat $D/clkgate_enable 2>/dev/null) clkscale=$(cat $D/clkscale_enable 2>/dev/null)" > /dev/kmsg

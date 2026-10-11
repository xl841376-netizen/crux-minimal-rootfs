#!/bin/sh
# 把 CPU 温度源适配成 GNOME Resources 认得的名字（bind mount 覆盖 name 文件，可逆、不改内核）
OV=/run/crux-sensor-adapt
mkdir -p $OV
i=0
while [ $i -lt 90 ]; do
  H=
  for h in /sys/class/hwmon/hwmon*; do
    n=$(cat "$h/name" 2>/dev/null)
    if [ "$n" = "cpu0_thermal" ]; then H="$h"; break; fi
  done
  if [ -n "$H" ]; then
    if [ "$(cat "$H/name" 2>/dev/null)" = "coretemp" ]; then exit 0; fi
    echo "coretemp" > "$OV/name"
    mount --bind "$OV/name" "$H/name" && logger -t crux-sensor-adapt "adapted $H -> coretemp"
    exit 0
  fi
  sleep 1
  i=$((i+1))
done
logger -t crux-sensor-adapt "timeout: cpu0_thermal not found"
exit 1

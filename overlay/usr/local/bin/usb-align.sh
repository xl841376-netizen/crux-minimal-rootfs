#!/bin/bash
# USB ECM 主动对齐v3: 链路校准就绪(carrier up)即立即连接, 不等宿主响应
# 由 usb-align.service (boot + usb0重连时) 触发
IF=usb0
[ -d /sys/class/net/$IF ] || { echo "usb0 不存在"; exit 0; }
OK=0
for i in $(seq 1 20); do
  if [ "$(cat /sys/class/net/$IF/carrier 2>/dev/null)" = "1" ]; then
    OK=1
    break
  fi
  sleep 0.5
done
ip link set $IF up 2>/dev/null
ip addr show $IF | grep -q '192.168.2.2/24' || ip addr add 192.168.2.2/24 dev $IF 2>/dev/null
ip neigh flush dev $IF 2>/dev/null
ping -c3 -W1 192.168.2.1 >/dev/null 2>&1 &
echo "[usb-align] $(date '+%F %T') carrier_ready=$OK" >> /var/log/usb-align.log 2>/dev/null
exit 0

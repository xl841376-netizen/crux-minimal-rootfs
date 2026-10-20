#!/bin/bash
# crux USB gadget: 纯 ECM 网卡（单 function）。由 usb-ecm-drd.sh 调用 start|stop
# 名称里的 acm 为历史遗留，当前仅 ECM。
G=/sys/kernel/config/usb_gadget/g1
UDC=a600000.usb
LOG=/dev/tty1
say(){ echo "[usb-gadget] $*" > $LOG 2>/dev/null; }
find_if(){
  local old="$1" n
  for i in /sys/class/net/*; do
    n=$(basename "$i")
    case "$n" in
      usb*|enx*|eth*) echo "$old" | grep -qw "$n" || { echo "$n"; return; } ;;
    esac
  done
}
stop(){ [ -d $G ] || return 0; echo "" > $G/UDC 2>/dev/null; rm -rf $G; say "stopped"; }
start(){
  stop
  modprobe libcomposite 2>/dev/null
  mkdir -p $G; cd $G || return 1
  echo 0x1d6b > idVendor
  echo 0x0104 > idProduct
  echo 0x0100 > bcdDevice
  echo 0x0200 > bcdUSB
  mkdir -p strings/0x409
  echo crux   > strings/0x409/serialnumber
  echo crux > strings/0x409/manufacturer
  echo crux > strings/0x409/product
  mkdir -p configs/c.1/strings/0x409
  echo "ECM" > configs/c.1/strings/0x409/configuration
  mkdir -p functions/ecm.usb0
  echo 02:11:22:33:44:66 > functions/ecm.usb0/dev_addr
  echo 02:11:22:33:44:55 > functions/ecm.usb0/host_addr
  ln -sf functions/ecm.usb0 configs/c.1/
  OLDIF=$(ls /sys/class/net | tr '\n' ' ')
  echo "$UDC" > UDC
  sleep 2
  IF=$(find_if "$OLDIF")
  if [ -n "$IF" ]; then
    ip link set "$IF" up
    ip addr add 192.168.2.2/24 dev "$IF" 2>/dev/null
    say "ECM up on $IF (192.168.2.2/24)"
  else
    say "bound, no new iface"
  fi
}
case "$1" in
  start) start ;;
  stop)  stop  ;;
  *) echo "usage: $0 start|stop"; exit 1 ;;
esac

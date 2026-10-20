#!/bin/sh
# crux: X50 PCIe Gen3(8GT/s) x2 - two-end LnkCtl2.TLS=3 then RC retrain, verify
EP=0001:01:00.0
RC=0001:00:00.0
log() { logger -t x50-gen3 "$*"; echo "[x50-gen3] $*"; }
i=0
while [ $i -lt 90 ]; do
    [ -e /sys/bus/pci/devices/$EP ] && break
    i=$((i+1)); sleep 2
done
[ -e /sys/bus/pci/devices/$EP ] || { log "endpoint not on bus, give up"; exit 0; }
log "endpoint present (waited $((i*2))s)"
rate()  { cat /sys/bus/pci/devices/$EP/current_link_speed 2>/dev/null; }
width() { cat /sys/bus/pci/devices/$EP/current_link_width 2>/dev/null; }
is8(){ case "$(rate)" in 8.0*) return 0;; *) return 1;; esac; }
if is8; then log "already $(rate) x$(width), skip"; exit 0; fi
n=0
while [ $n -lt 4 ]; do
    n=$((n+1))
    setpci -s $EP CAP_EXP+30.w=0x0003 2>/dev/null
    setpci -s $RC CAP_EXP+30.w=0x0003 2>/dev/null
    sleep 1
    setpci -s $RC CAP_EXP+10.w=0x20 2>/dev/null
    sleep 3
    log "try#$n EP=$(rate) x$(width)"
    if is8; then log "OK $(rate) x$(width)"; exit 0; fi
done
log "failed after $n tries, still $(rate) x$(width)"
exit 0

#!/bin/sh
# crux touch IC watchdog v2
# Strategy: every INTERVAL seconds, look at the ST FTS hardware IRQ count
# in /proc/interrupts (the "fts" line, IRQ msmgpio 122).
#   - count increased  -> touch IC is alive, do nothing
#   - count unchanged  -> IRQ stopped / IC hung, write ic_recover to reset it
LOG_TAG="crux-touch-watchdog"
STATE_LOG="/var/log/crux-touch-watchdog.log"
INTERVAL=120
COOLDOWN=20

say() {
    logger -t "$LOG_TAG" "$*" 2>/dev/null
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$STATE_LOG" 2>/dev/null
}

find_dev() {
    for d in /sys/bus/i2c/devices/*-0049; do
        [ -e "$d/ic_dump" ] && { echo "$d"; return 0; }
    done
    return 1
}

irq_count() {
    awk '/fts/ {s=0; for (i=2; i<=9; i++) s+=$i; print s; exit}' /proc/interrupts
}

recover() {
    dev="$1"
    say "RECOVER: $2 -> writing ic_recover on $dev"
    echo 1 > "$dev/ic_recover" 2>/dev/null
    sleep "$COOLDOWN"
}

say "watchdog v2 started (interval=${INTERVAL}s, irq-based)"
last=$(irq_count)
say "baseline fts irq count=$last"

while :; do
    sleep "$INTERVAL"
    now=$(irq_count)
    if [ -z "$now" ]; then
        say "cannot read fts irq line from /proc/interrupts"
        continue
    fi
    if [ "$now" -gt "$last" ] 2>/dev/null; then
        say "irq ok: $last -> $now"
        last="$now"
        continue
    fi
    dev=$(find_dev)
    if [ -z "$dev" ]; then
        say "no fts device (-0049) present, skip recover"
        last="$now"
        continue
    fi
    recover "$dev" "no irq increase within ${INTERVAL}s (count $last -> $now)"
    last=$(irq_count)
    [ -z "$last" ] && last=0
done
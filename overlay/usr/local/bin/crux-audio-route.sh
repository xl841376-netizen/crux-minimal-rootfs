#!/bin/sh
# [crux 2026-10-20] 开机把播放路由固定到扬声器通路（QUAT_MI2S -> CS35L41）
# 原因：ASoC 的 FE 若没有任何 BE 被 mixer 打开，open 会直接返回 EINVAL
#       （dmesg: "no backend DAIs enabled for MultiMedia1"）。
for i in $(seq 1 40); do
    if [ -e /dev/snd/controlC0 ]; then
        amixer -c0 cset "name=QUAT_MI2S_RX Audio Mixer MultiMedia1" on  >/dev/null 2>&1
        amixer -c0 cset "name=SLIMBUS_0_RX Audio Mixer MultiMedia1" off >/dev/null 2>&1
        logger -t crux-audio "route set: QUAT_MI2S_RX MultiMedia1=on, SLIMBUS_0_RX=off"
        exit 0
    fi
    sleep 1
done
logger -t crux-audio "controlC0 not found, route NOT set"
exit 1
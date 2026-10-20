#!/bin/sh
# X50 feed-only：只喂 Sahara 镜像，不切电（热复位后用）
# 前置：模组已处于 Sahara/SBL 阶段（/dev/mhi_pipe_2 存在）
LOG=/var/log/x50-feed.log
exec >>$LOG 2>&1
echo "=== x50-feed-only $(date) ==="
K=$(uname -r)
E=/lib/modules/$K/extra

# 禁 X50 PCIe 运行态 PM（M3 唤醒会 -5 掉链路）
for d in /sys/bus/pci/devices/*; do
    v=$(cat $d/vendor 2>/dev/null)
    [ "$v" = "0x17cb" ] && echo on > $d/power/control 2>/dev/null
done

for i in $(seq 1 30); do [ -e /dev/crux-esoc ] && break; sleep 1; done
for m in phy-qcom-qmp-pcie crux_esoc gnss wwan qrtr-mhi; do modprobe $m 2>/dev/null; done
for k in mhi.ko mhi_net.ko mhi_pci_generic.ko mhi_sahara.ko mhi_wwan_ctrl.ko; do
    grep -q "$k" /proc/modules 2>/dev/null && continue
    insmod $E/$k 2>>$LOG
    sleep 1
done
lsmod | grep -E "^(mhi|mhi_sahara|mhi_pci_generic|mhi_wwan_ctrl)" >>$LOG

# 等 Sahara 通道；拿不到就退出（绝不 cycle）
for i in $(seq 1 20); do [ -e /dev/mhi_pipe_2 ] && break; sleep 1; done
if [ ! -e /dev/mhi_pipe_2 ]; then
    echo "ERROR: no /dev/mhi_pipe_2 (modem not in Sahara); refusing to cycle"
    echo "=== x50-feed-only FAILED $(date) ==="
    exit 3
fi

timeout 180 python3 -u /root/x50mods/x50_sahara_loader.py --dev /dev/mhi_pipe_2 --sessions 12 --idle-timeout 15 | tail -2
echo "--- fed $(date) ---"

systemctl restart x50-efs-sync.service 2>/dev/null
setsid nohup /usr/local/bin/pm_service_native -V > /var/log/x50-pm-service.log 2>&1 < /dev/null &

for i in $(seq 1 15); do [ -e /sys/bus/mhi/devices/mhi0_IP_HW_OFFLOAD_0 ] && break; sleep 1; done
if [ -e /sys/bus/mhi/devices/mhi0_IP_HW_OFFLOAD_0 ]; then
    if ! grep -q "^ipa_mhi_proxy " /proc/modules; then
        insmod $E/ipa_mhi_proxy.ko 2>>$LOG && echo "ipa_mhi_proxy loaded" || echo "ipa_mhi_proxy load FAILED"
    fi
else
    echo "no mhi0_IP_HW_OFFLOAD_0 device; proxy not loaded"
fi

echo "=== x50-feed-only done $(date) ==="
# [crux 2026-10-20] mission mode 的强制 suspend/resume（PHY 已切）之后，
# 再把链路抬回 Gen3/8GT/s。gen3 自身有 ExecCondition 保护，非 mission 时跳过。
if [ -e /sys/bus/mhi/devices/mhi0_IP_HW_OFFLOAD_0 ]; then
    systemctl daemon-reload
    systemctl restart --no-block x50-gen3 2>/dev/null || true
    echo "x50-gen3 triggered after mission mode $(date)"
fi

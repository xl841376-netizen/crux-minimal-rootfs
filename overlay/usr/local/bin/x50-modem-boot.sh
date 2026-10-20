#!/bin/sh
# X50 开机流程（mhi_sahara 版）：加载新 MHI 栈 -> esoc cycle -> 喂 Sahara 镜像 -> 起 persist EFS 应答器
LOG=/var/log/x50-boot.log
exec >>$LOG 2>&1
echo "=== x50-modem-boot $(date) (mhi_sahara) ==="
K=$(uname -r)
E=/lib/modules/$K/extra

# [crux] 禁掉 X50 PCIe 设备的运行态 PM（M3 唤醒会 -5 掉链路）
for d in /sys/bus/pci/devices/*; do
    v=$(cat $d/vendor 2>/dev/null); dv=$(cat $d/device 2>/dev/null)
    if [ "$v" = "0x17cb" ]; then echo on > $d/power/control 2>/dev/null; fi
done

# 等内核模块基础设施与 esoc 设备
for i in $(seq 1 60); do [ -e /dev/crux-esoc ] && break; sleep 1; done
# 先装 MHI 栈（mhi 现在是模块；不再用自写的 mhi_userchan）
for m in phy-qcom-qmp-pcie crux_esoc gnss wwan qrtr-mhi; do modprobe $m 2>/dev/null; done
for k in mhi.ko mhi_net.ko mhi_pci_generic.ko mhi_sahara.ko mhi_wwan_ctrl.ko; do
    grep -q "$k" /proc/modules 2>/dev/null && continue
    insmod $E/$k 2>>$LOG
    sleep 1
done
lsmod | grep -E "^(mhi|mhi_sahara|mhi_pci_generic|mhi_wwan_ctrl)" >>$LOG
# 基带冷复位 + 喂镜像
for i in $(seq 1 60); do [ -e /sys/bus/pci/devices/0001:01:00.0 ] && break; sleep 1; done
timeout 60 python3 /root/x50mods/x50_esoc.py cycle || echo "cycle rc=$?"
sleep 2
[ -e /dev/mhi_pipe_2 ] || echo "WARNING: no /dev/mhi_pipe_2 after cycle"
if [ -e /dev/mhi_pipe_2 ]; then
    timeout 180 python3 -u /root/x50mods/x50_sahara_loader.py --dev /dev/mhi_pipe_2 --sessions 12 --idle-timeout 15 | tail -2
    echo "--- fed $(date) ---"
# [crux] sahara 灌完 -> 通知 esoc：镜像完成 / 模组进任务模式
#      内核侧据此对 X50 做 PCIe D3hot->D0 + 链路重训
/usr/local/sbin/x50-esoc-notify 1 || echo "notify img-xfer-done failed"
sleep 2
/usr/local/sbin/x50-esoc-notify 2 || echo "notify boot-done failed"
else
    echo "--- skip feed ---"
fi
# persist EFS 应答器（mhi_sahara 提供 /dev/mhi_pipe_10）
systemctl restart x50-efs-sync.service 2>/dev/null
# apollo 的 pm service（可选）
setsid nohup /usr/local/bin/pm_service_native -V > /var/log/x50-pm-service.log 2>&1 < /dev/null &

# IPA-MHI proxy: 告诉内建 modem 外挂 modem 的 proxy 门铃（QMI_IPA_MHI_READY_IND 0x3c）
for i in $(seq 1 15); do [ -e /sys/bus/mhi/devices/mhi0_IP_HW_OFFLOAD_0 ] && break; sleep 1; done
if [ -e /sys/bus/mhi/devices/mhi0_IP_HW_OFFLOAD_0 ]; then
    if ! grep -q "^ipa_mhi_proxy " /proc/modules; then
        insmod $E/ipa_mhi_proxy.ko auto_uc=1 2>>$LOG && echo "ipa_mhi_proxy loaded" || echo "ipa_mhi_proxy load FAILED"
    fi
else
    echo "no mhi0_IP_HW_OFFLOAD_0 device; proxy not loaded"
fi

echo "=== x50-modem-boot done $(date) ==="
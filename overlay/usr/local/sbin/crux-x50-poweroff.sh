#!/bin/sh
# crux: AP 关机/重启前，让外挂 X50（SDX50M）干净下线。
#
# 原厂语义（esoc-mdm-drv.c: mdm_subsys_power_off）：
#   1) cmd_exe(ESOC_PWR_OFF)  —— 请求基带自己准备（sysmon）
#   2) esoc_client_link_power_off(MDM_DOWN) —— 通知客户端（mhi_arch_qcom）先停 MHI
#   3) cmd_exe(ESOC_FORCE_PWR_OFF) —— 按住复位线，真正断电
# 我们没有 1)（那是 modem 侧 sysmon 协议），所以把重心放在 2)+3)：
# 先让 MHI 受控下线，再摘 PCIe 端点，最后按住复位 —— 这样就不会再出现
# "链路中途消失 -> AER 风暴 / Recovery failed(-11) / 根端口 reset 失败"。

LOG=/var/log/crux-x50-poweroff.log
{
	echo "=== $(date) crux-x50-poweroff start ==="

	# 0) 常驻的 EFS 应答器占着 /dev/mhi_pipe_10，先松开（否则它会在链路消失时报错刷屏）
	systemctl stop x50-efs-sync.service 2>/dev/null || true
	systemctl stop x50-modem-boot.service 2>/dev/null || true
	pkill -f "[x]50_sahara" 2>/dev/null || true
	pkill -f "[x]50_efs" 2>/dev/null || true
	sleep 1

	# 1) 切电。
	#    优先 force_pwr_off：crux_esoc 里 FORCE 语义 = 原厂 "pull the reset line low"，
	#    **只按住复位、不动 MHI/PCIe** —— AP 正在关机时绝不允许做
	#    mhi_power_down()/pci_stop_and_remove_bus_device() 这类会永久等待的操作
	#    （实测踩过：用 pwr_off 路径把整个重启卡死，机器起不来）。
	#    老版本 x50_esoc.py 没有 force_pwr_off 才退回 pwr_off。
	if [ -f /root/x50mods/x50_esoc.py ]; then
		if grep -qE "\"force_off\"|force_off" /root/x50mods/x50_esoc.py; then
			timeout 8 python3 /root/x50mods/x50_esoc.py force_off 2>&1 \
				|| echo "force_off rc=$? (超时或失败)"
		else
			echo "WARN: x50_esoc.py 无 force_off 子命令，退回 pwr_off（可能阻塞！）"
			timeout 8 python3 /root/x50mods/x50_esoc.py pwr_off 2>&1 \
				|| echo "pwr_off rc=$? (超时或失败)"
		fi
	else
		echo "x50_esoc.py 不在，跳过"
	fi

	# 2) 兜底：万一上面的路径没走完，直接按 FORCE 语义按住复位线
	#    （libgpiod v2: gpioset -c gpiochip2 8=0；v1: gpioset gpiochip2 8=0）
	gpioset -c gpiochip2 8=0 2>/dev/null \
		|| gpioset gpiochip2 8=0 2>/dev/null \
		|| echo "gpio fallback: 无可用 gpioset（正路 force_off 成功即可忽略）"

	echo "=== $(date) crux-x50-poweroff done ==="
} >> $LOG 2>&1

exit 0
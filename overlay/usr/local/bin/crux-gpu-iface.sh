#!/bin/sh
# 把 GPU 数据做成 DRM 标准接口（谁都能读，GNOME Resources 走 OtherGpu 分支）
DEV=/run/crux-gpu-iface/card0/device
HWM=$DEV/hwmon/hwmon0
TARGET=/sys/class/drm/card0

mkdir -p $HWM

# uevent：让上层能识别这个设备
cat > $DEV/uevent <<UEOF
DRIVER=msm
OF_NAME=display-controller
OF_FULLNAME=/soc@0/display-subsystem@ae00000/display-controller@ae01000
OF_COMPATIBLE_0=qcom,sm8150-dpu
OF_COMPATIBLE_N=1
MODALIAS=of:Ndisplay-controllerT(null)Cqcom,sm8150-dpu
UEOF

# 初始占位
for f in gpu_busy_percent mem_info_vram_used mem_info_vram_total mem_info_shared_used; do
    [ -f "$DEV/$f" ] || echo 0 > "$DEV/$f"
done

# 挂载（幂等）
if ! grep -q " $TARGET " /proc/mounts 2>/dev/null; then
    if mount --bind "$DEV" "$TARGET"; then
        logger -t crux-gpu-iface "bind mounted $DEV -> $TARGET"
    else
        logger -t crux-gpu-iface "mount FAILED"
    fi
fi

# 循环刷新（每 2 秒）
while true; do
    python3 /usr/local/bin/crux-gpu-sample.py
    sleep 2
done

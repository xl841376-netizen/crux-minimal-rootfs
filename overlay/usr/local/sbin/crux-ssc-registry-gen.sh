#!/bin/sh
# crux: 开机生成 SSC 传感器注册表，也就是 HexagonRPCD 文件树里的 sensors/registry。
# 生成工具来自上游 linux-msm/hexagonrpc 的 tools/sscregistrygen，装在 /usr/local/bin。
# 已经生成过就跳过；想把成品重做，把注册表目录里的文件删掉再重启，或者直接跑本脚本。

set -u

CONFIG_DIR=/usr/share/qcom/sensors/config
REG_DIR=/usr/share/qcom/sensors/registry/registry
GEN=/usr/local/bin/sscregistrygen

# 平台名优先读 socinfo，主线一般没有 hw_platform 这个节点，就回退到 CRUX
PLATFORM=$(cat /sys/devices/soc0/hw_platform 2>/dev/null || true)
[ -z "$PLATFORM" ] && PLATFORM=CRUX
SOC_ID=$(cat /sys/devices/soc0/soc_id 2>/dev/null || true)
[ -z "$SOC_ID" ] && SOC_ID=339

if [ ! -d "$CONFIG_DIR" ]; then
    echo "crux-ssc-registry: 缺少配置目录 $CONFIG_DIR，跳过"
    exit 0
fi
if [ ! -x "$GEN" ]; then
    echo "crux-ssc-registry: 缺少生成工具 $GEN，跳过"
    exit 0
fi

mkdir -p "$REG_DIR"

COUNT=$(find "$REG_DIR" -maxdepth 1 -type f -name "*" 2>/dev/null | wc -l)
if [ "$COUNT" -ge 10 ]; then
    echo "crux-ssc-registry: 注册表已存在（$COUNT 个文件），跳过生成"
    exit 0
fi

echo "crux-ssc-registry: 开始生成，platform=$PLATFORM soc_id=$SOC_ID"
"$GEN" -p "$PLATFORM" -s "$SOC_ID" "$CONFIG_DIR" "$REG_DIR"
RC=$?
if [ "$RC" -eq 0 ]; then
    echo "crux-ssc-registry: 生成完成，现有 $(find "$REG_DIR" -maxdepth 1 -type f | wc -l) 个文件"
else
    echo "crux-ssc-registry: 生成失败，返回码 $RC"
fi
exit 0

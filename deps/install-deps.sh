#!/bin/sh
# crux 最小 rootfs · 基础包安装（在线）
# 用法:
#   sudo ./deps/install-deps.sh              # 默认 standard（推荐）
#   sudo ./deps/install-deps.sh minimal      # 只要音频能响
#   sudo ./deps/install-deps.sh full         # 再加 gstreamer 媒体栈（~945MB）
# 环境变量: MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LEVEL=${1:-standard}
LIST="$HERE/lists/$LEVEL.list"
[ -f "$LIST" ] || { echo "找不到清单: $LIST（可选: minimal|standard|full）"; exit 1; }

PKGS=$(grep -vE '^[[:space:]]*(#|$)' "$LIST" | tr '\n' ' ')
echo "== 等级: $LEVEL"
echo "== 包数: $(echo $PKGS | wc -w)"
if [ -n "${MIRROR:-}" ]; then
    echo "== 换源: $MIRROR"
    sed -i "s|http://ports.ubuntu.com/ubuntu-ports|$MIRROR|g" /etc/apt/sources.list 2>/dev/null || true
    sed -i "s|http://archive.ubuntu.com/ubuntu|$MIRROR|g" /etc/apt/sources.list 2>/dev/null || true
    apt-get update
fi
echo "== 安装（--no-install-recommends，保持最小）"
# shellcheck disable=SC2086
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PKGS
echo "== 完成"
echo
echo "后续（包管理器不管的部分）："
echo "  1) 固件：/lib/firmware/qcom/sm8150/xiaomi/crux/*.mbn、ath10k/WCN3990/hw1.0/*、qcom/sdx50m/*、regulatory.db"
echo "  2) 内核模块：modules/*.ko -> /usr/lib/modules/\$(uname -r)/extra/"
echo "  3) 启用服务：见 README §3 ③ 的 enable 列表"

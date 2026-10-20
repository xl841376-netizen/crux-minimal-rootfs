#!/bin/sh
# crux 最小 rootfs · 离线 deb 缓存（在有网的同架构机器上跑）
# 用法:
#   ./deps/fetch-debs.sh standard        # 产物在 deps/debs/，同时生成 install-offline.sh
#   然后把整个 deps/debs/ 目录拷到目标机，执行其中的 install-offline.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LEVEL=${1:-standard}
LIST="$HERE/lists/$LEVEL.list"
OUT="$HERE/debs"
[ -f "$LIST" ] || { echo "找不到清单: $LIST"; exit 1; }
mkdir -p "$OUT"
PKGS=$(grep -vE '^[[:space:]]*(#|$)' "$LIST" | tr '\n' ' ')
echo "== 下载 $LEVEL 的 deb（含依赖）到 $OUT"
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends --download-only \
    -o Dir::Cache::archives="$OUT" $PKGS
# 清掉 partial 目录里的空壳，生成离线安装脚本
rm -rf "$OUT/partial"
cat > "$OUT/install-offline.sh" <<'EOS'
#!/bin/sh
set -eu
cd "$(dirname "$0")"
echo "== 离线安装 $(ls *.deb | wc -l) 个 deb"
dpkg -i ./*.deb || apt-get -f install -y
EOS
chmod +x "$OUT/install-offline.sh"
echo "== 完成：$(ls "$OUT"/*.deb 2>/dev/null | wc -l) 个 deb，$(du -sh "$OUT" | cut -f1)"
echo "== 拷走整个 deps/debs/ 目录，在目标机执行 ./install-offline.sh"

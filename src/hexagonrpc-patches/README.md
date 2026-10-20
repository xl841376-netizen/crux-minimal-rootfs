# hexagonrpcd crux 修改补丁

本目录包含 crux（小米 9 Pro 5G / SM8150）上使用的 hexagonrpcd 相对上游的改动，用于履行 GPLv3 要求的“提供对应源码”义务。

## 上游
- 仓库：https://github.com/linux-msm/hexagonrpc
- 基线 commit：598b591（tests: add unit test for hexagonrpc function）
- 许可：GPLv3（上游 COPYING）

## 改动内容
- hexagonrpcd/hexagonfs*.c：文件系统虚拟目录、映射与平台子类型名适配 crux 的 /usr/share/qcom 布局
- hexagonrpcd/apps_std.c：增加 fremove / frename 实现，fwrite 走 hexagonfs_write
- hexagonrpcd/listener.c：解析 inbufs 的 TYPEDEF 序列，ADSP listener 输入缓冲固定 64 KiB
- hexagonrpcd/rpcd_builder.c：builder 结构调整
- hexagonrpcd/interface/apps_std.{c,h}：补齐 fwrite（msg_id 5）、fremove（msg_id 24）、frename（msg_id 33）的 method def
- tests/test_hexagonfs.c：单元测试

## 应用与构建
```sh
git clone https://github.com/linux-msm/hexagonrpc
cd hexagonrpc && git checkout 598b591
git apply /path/to/crux-hexagonrpcd-20261020.patch
meson setup build && ninja -C build
# 产物：build/hexagonrpcd/hexagonrpcd
```
依赖：libqrtr（>=1.2）、protobuf-c、meson/ninja。

## 说明
- 本补丁在 commit 598b591 上可干净应用并成功编译（产物 147,456 字节，aarch64）。
- 分发镜像中现有的 /usr/local/bin/hexagonrpcd 为 141,800 字节，是历史构建产物，与上述源码重建结果可能不完全一致；如需严格对应，请用本补丁重建后替换。
- 补丁中 apps_std 的三个 method def（fwrite/fremove/frename）此前缺失，本次一并补齐，否则源码无法编译。

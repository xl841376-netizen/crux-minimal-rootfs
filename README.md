# crux 最小 rootfs（Xiaomi Mi 9 Pro 5G / SM8150）

主线 Linux（`7.3.0-rc5-crux73`）+ Ubuntu 26.04.1 LTS（`resolute`）aarch64 的设备适配层与构建脚本。

Release 的 `crux-rootfs-resolute-arm64-*.tar.zst` 是完整系统，写入分区即可启动，不需要另行下载 Ubuntu 镜像。
内核 `Image`、`.dtb`、`initramfs` 与 grub 在 ESP，不在包内。

## 1. 组成

| 层 | 内容 | 本仓库 |
|---|---|---|
| L0 基础系统 | Ubuntu 26.04.1 aarch64（systemd、udev、dbus、kmod、apt、openssh、sudo、python3…） | Release 的 tar.zst 已含（debootstrap 生成） |
| L1 包清单 | 子系统所需的通用 apt 包 | `deps/lists/` |
| L2 设备适配层 | `overlay/`：systemd 单元、脚本、udev 规则、modprobe/sysctl 配置、UCM、WirePlumber 规则 | ✅ |
| L3 子系统用户态 | `overlay/usr/local/`：`npu`/`npuctl`/`npu-svc`、`hexagonrpcd`+`libhexagonrpc`/`libqrtr`、`rmtfs`/`tqftpserv`/`pd-mapper` | ✅ |
| 内核模块 | `modules/` | ✅ |

### 1.1 包清单

| 档 | 内容 | 包数 | 下载 | 安装后 |
|---|---|---|---|---|
| `minimal` | 音频栈（`alsa-ucm-conf`/`alsa-utils`/`libasound2t64`/`pipewire`+`-pulse`+`-alsa`/`wireplumber`） | 166 | 41.9 MB | 161 MB |
| `standard` | minimal + `network-manager`/`wpasupplicant`/`rfkill`/`iw`/`openssh-server` + `modemmanager`/`libqmi-utils`/`libmbim-utils` + `python3`/`sudo`/`e2fsprogs`/`dosfstools` | 239 | 63.9 MB | 256 MB |
| `full` | standard + gstreamer 媒体栈 + `v4l-utils` | 486 | 945 MB | 1775 MB |
| `sda37` | 取自在役机 sda37 的 `dpkg --get-selections`，含 GNOME + gdm3 | 1666 | — | — |

```bash
# 在线安装
sudo ./deps/install-deps.sh standard
MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports sudo -E ./deps/install-deps.sh standard

# 离线 deb
./deps/fetch-debs.sh standard        # 产物 deps/debs/*.deb + install-offline.sh
```

## 2. 仓库结构

| 路径 | 内容 |
|---|---|
| `overlay/` | 适配层 + 子系统用户态，按 rootfs 绝对路径存放，覆盖到根即可 |
| `modules/` | out-of-tree 内核模块（装到 `/lib/modules/<kver>/kernel/`） |
| `src/` | 有源码、可自行修改的私有部件源码（`src/iris-vaapi/`），编译产物按 rootfs 绝对路径放 `overlay/` |
| `build.sh` | debootstrap → 套 overlay → 装模块 → 启用服务 |
| `mkimage.sh` | 构建完整 rootfs 包（debootstrap → 装包 → overlay → 固件/模块 → 打包） |
| `tools/fetch-firmware.sh` | 从设备拉固件与内核模块 |
| `deps/` | 包清单 + 在线安装 / 离线 deb 脚本 |
| `MANIFEST.txt` | 文件路径 + sha256 |

不入库：`/root/.ssh/*`、SSH 主机密钥、无线凭据（NM/netplan 里的 PSK）、`/root` 私人材料、日志、固件二进制。

私有部件按有无源码分开存放：无源码、不能改的厂商二进制（固件、闭源驱动）不进本仓库，由内核仓库 `fw_extra/` 与 `fw-<日期>` 资产发布；有源码可改的（如 `iris-vaapi`）源码进 `src/`，预编译产物按绝对路径放 `overlay/`。

## 3. 安装

### 3.1 用 Release 的包

最新：`rootfs-20261020-0753`（GitHub Actions 构建，`package_set=sda37`）

| 文件 | 说明 |
|---|---|
| `crux-rootfs-resolute-arm64-20261020.tar.zst` | 1.43 GB（解压后系统约 5.2 GB + 固件 417 MB + 模块 361 MB） |
| `SHA256SUMS` | `sha256sum -c SHA256SUMS` |

该包内容：包集 `deps/lists/sda37.list`（1666 包，含 GNOME+gdm3、`ibus-libpinyin`、`fonts-noto-cjk`、`docker.io`、`build-essential`）；`/usr/local/bin` 12 个 ELF + `libqrtr.so.1.2`/`libhexagonrpc.so.0.5`；`default.target=graphical.target`，`display-manager.service -> gdm3.service`；用户 `crux`（uid 1000，组 sudo,audio,video,input,render,netdev,dialout,lp,tty，初始密码 `crux`）；时区 Asia/Shanghai，locale zh_CN.UTF-8；内核模块 1652 个；`fstab` 按 `PARTLABEL=linux-root`；不含 WiFi 密码与私钥（CI 校验 `etc/netplan/*.yaml` 为 0）。

一键刷入（自动识别 fastboot 与 mass 盘，缺分区时自动创建，写系统与 ESP）：

```bash
sudo ./tools/install-to-disk.sh --auto \
  --tar crux-rootfs-resolute-arm64-20261020.tar.zst \
  --efi BOOTAA64.EFI --kernel Image \
  --dtb sm8150-xiaomi-crux-73.dtb --initrd initramfs.cpio.gz \
  --mu Mu-crux.img --root-size 24G --esp-size 512M
```

已知分区时去掉 `--auto`，改用 `--root <分区> --esp <分区>`。

手动步骤：

```bash
# ① 建根分区（默认标签 linux-root，对应 fstab；换标签用 --root-label 或写盘后改 /etc/fstab）
sudo sgdisk -n 0:0:+24G -t 0:8300 -c 0:linux-root /dev/sda
sudo mkfs.ext4 -L linux-root /dev/sda38

# ② 解压
sudo mount /dev/sda38 /mnt
sudo tar --zstd -xpf crux-rootfs-resolute-arm64-20261020.tar.zst -C /mnt
sudo sync && sudo umount /mnt

# ③ 取 UUID，写进 ESP 的 EFI/crux/grub.cfg
sudo blkid -s UUID -o value /dev/sda38
```

```text
linux (hd0,gpt35)/EFI/crux/Image74 root=UUID=<上面的UUID> rootwait rw ...
```

ESP 需已有 `Image`、`*.dtb`、`initramfs.cpio.gz`、`grub.cfg`（不在本包内）。

首次开机：

```bash
passwd                      # root 默认密码 root
ls /sys/class/net           # wlan0；nmcli 连网
speaker-test -t sine -c 2   # 前台跑会占住会话，用 setsid nohup
```

写入方式：已运行的 Linux 里 `mount` + `tar`；或 Android 侧 `modprobe g_mass_storage file=/dev/block/sda removable=1` 让 PC 当普通磁盘写（只追加新分区，不动 sda1–sda34）；或 `dd if=xxx.img of=/dev/sdX bs=4M status=progress`。

### 3.2 自己构建

```bash
./tools/fetch-firmware.sh root@crux.local ./fw     # → ./fw/firmware（约417MB） ./fw/modules（约363MB）
sudo ./mkimage.sh /root/out --fw-dir ./fw
#   --level minimal|standard|full   --selections deps/lists/sda37.list   --private <目录>
#   --suite resolute  --mirror <镜像>  --kver 7.3.0-rc5-crux73  --no-fw
#   --root-uuid <UUID>  --root-label linux-root
```

流程：`debootstrap minbase` → 按清单装包 → 套 `overlay/` → 套 `--private`（不入库的私有配置，如 netplan 认证数据）→ 放固件与模块 → 写 `fstab`/`hostname`/root 密码 → `systemctl --root` 启用单元 → 权限归一 → 打包。

### 3.3 三处对应关系

1. `/etc/fstab` 的 `PARTLABEL=` 与分区标签一致
2. grub 的 `root=` 与分区 UUID 一致
3. `/lib/modules/` 版本号与 ESP 上内核的 `uname -r` 一致（否则模块不加载）；换内核构建时加 `--kver`

## 4. 子系统配套

| 子系统 | 基础包（L1） | 本仓库提供（L2/L3） | 其它依赖 | 状态 |
|---|---|---|---|---|
| 显示 / GPU | `mesa-*`、`libdrm-*`、`libgl1`、`libvulkan1` | `crux-display/te-sync`（内核侧）、`crux-gpu-iface.service` | 固件 `qcom/a640_gmu.bin`、`qcom/a630_sqe.fw`、`a640_zap.mbn` | 可用 |
| 触摸 | `libinput`、桌面栈 | `crux-touch-watchdog.service` | 固件 `ftm5_fw.ftb`；`fts` 驱动（`TOUCHSCREEN_STM_FTS_DOWNSTREAM`） | 可用 |
| UFS 存储 | `e2fsprogs`、`dosfstools` | `crux-ufs-stable.service`（`auto_hibern8=0`、LUN `power/control=on`）+ `ufs-nopm.service`（`rpm_lvl`/`clkgate_enable`/`clkscale_enable=0`）+ `90-ufs-writeback.conf` | — | 可用 |
| WiFi（WCN3990） | `network-manager`、`wpasupplicant`、`rfkill`、`iw` | `modules-load.d/crux-wifi.conf`（`ath10k_snoc`）、`ath10k` 日志降级 | `ath10k/WCN3990/hw1.0/*` + `qcom/sm8150/xiaomi/crux/wlanmdsp.mbn`；`regulatory.db`；`cfg80211.ieee80211_regdom=CN` | 可用 |
| 音频 | `alsa-ucm-conf`、`alsa-utils`、`libasound2t64`、`pipewire`+`-pulse`+`-alsa`、`wireplumber` | `ucm2/conf.d/sm8150/{sm8150,HiFi}.conf`、`wireplumber.conf.d/{51-crux-fmt,52-crux-noproaudio}.conf`、`crux-audio-route.service` | dts `&sound { model = "… sm8150" }`；ADSP（`adsp.mbn`） | 可用（Speaker + Earpiece） |
| NPU | `python3` | `npu`、`npuctl`、`npu-svc`、`npu-boot.service`、`npu-svc.service`、`msm_qmp.ko`、`npu_boot24.ko`、`modules-load.d/msm_qmp.conf` | 固件 `npu.mdt`/`npu.b*`；`/dev/msm_npu` | 可用（InceptionV3） |
| 传感器（SSC/SLPI） | `python3` | `hexagonrpcd` + `libhexagonrpc.so.0.5`、`libqrtr.so.1.2`、`chrecd`、`resources*`、`ssccli`、`sscregistrygen`、`crux-ssc-registry.service`、`crux-fastrpc-guard.service`、`crux-sensor-adapt.service`、`wait-dsp-ready.sh` | 固件 `slpi.mbn`；`/dev/fastrpc-*` | 可用 |
| 视频编解码（iris/VPU） | `gstreamer1.0-*`、`v4l-utils` | `iris-vpu.service`、`99-qcom-iris-dmaheap.rules`、`modprobe.d/99-qcom-iris.conf`（`cached_capture=1`）、`blacklist-crux-video.conf` | 固件 `venus.mbn` | 可用 |
| 内置基带（mpss） | `modemmanager`、`libqmi-utils`、`libmbim-utils` | `rmtfs`/`tqftpserv`/`pd-mapper`、`modem-mnt.service`、`qcom-subsys-start.service/.timer` | 固件 `qcom/sm8150/xiaomi/crux/{modem,adsp,cdsp,slpi}.mbn`；分区 `modemst1/2`、`fsc`、`fsg` | 子系统 running；注册/数据未验证 |
| USB（ECM/ACM） | `usbutils`、`libusb` | `usb-gadget-acm.service`、`usb-align.service` | `qcom_usb_vbus-regulator.ko`、`modules-load.d/crux-usb.conf` | 可用 |
| 电源 / 充电 / 关机链 | `systemd` | `crux-charger-init.service`、`crux-markshutdown.service`、`crux-crashsave.service`、`dmesg-snap.service`、`power-snap.service`、`crux-kmsg-tap.service`、`99-printk-quiet.conf` | `pm8150b` charger/fuel-gauge 驱动 | 可用 |
| 交换空间 | — | `crux-swap.service`：`/etc/crux-swap.conf` 全参数化，`SWAP_ENABLE=0` 默认关 | — | 默认无 swap |
| 外挂 X50 / SIM | — | `x50-*` 单元与程序按原路径就位，默认不 enable；开关 `crux-sim-x50` | 固件 `qcom/sdx50m/*` | 未跑通，默认不启用 |
| 相机 | — | — | — | 未适配 |

## 5. 适配层清单

### 5.1 systemd 单元

| 单元 | 作用 | 开机启用 |
|---|---|---|
| `rmtfs.service` | Qualcomm remotefs（EFS 读写） | ✅ |
| `tqftpserv.service` | QRTR TFTP（给 DSP/模组发固件） | ✅ |
| `pd-mapper.service` | 保护域映射 | ✅ |
| `hexagonrpcd-sdsp.service` | 传感器 DSP 的 FastRPC 文件服务 | ✅ |
| `crux-ssc-registry.service` | 生成 SSC 传感器 registry 文件树 | ✅ |
| `iris-vpu.service` | 加载 `videocc-sm8150`/`system_heap`/`cma_heap`/`qcom_iris` | ✅ |
| `npu-svc.service` | NPU 常驻服务（`/run/npu.sock`） | ✅ |
| `npu-boot.service` | NPU PAS 开机序列（`insmod npu_boot24.ko`） | ⛔ |
| `crux-fastrpc-guard.service` | FastRPC 守护 | ✅ |
| `crux-touch-watchdog.service` | 触摸 IC 体检 + 自恢复 | ✅ |
| `crux-gpu-iface.service` | GPU 统计暴露为 DRM 接口 | — |
| `crux-sensor-adapt.service` | hwmon → `cpu-thermal` 等标准名 | — |
| `usb-gadget-acm.service` / `usb-align.service` | USB ECM gadget / ARP 对齐 | ✅ |
| `qsee-supplicant.service` / `qsee-app-loader@.service` | Qualcomm TEE 服务 / 应用加载器 | ✅ |
| `crux-audio-route.service` | 开机打开 BE mixer（`QUAT_MI2S_RX Audio Mixer MultiMedia1=on`） | ✅ |
| `crux-time-sync.service` + `.timer` | 开机校时 + 每 6 小时（RTC 无驱动） | ✅ |
| `crux-swap.service` | 默认全关（`SWAP_ENABLE=0`） | ⛔ |
| `crux-ufs-stable.service` / `ufs-nopm.service` | UFS 两种加固（标准 / QCOM 私有 sysfs） | ✅ |
| `crux-charger-init.service` | 开机设置 SMB5 的 ICHG | ✅ |
| `crux-crashsave.service` | 上一轮 dmesg 尾部写到 ESP（`LASTBOOT.TXT`/`CRASH.TXT`） | ✅ |
| `crux-markshutdown.service` | 打干净关机标记（`WantedBy=shutdown.target`） | ✅ |
| `qcom-subsys-start.service` + `.timer` | 拉 `mpss`/`adsp`/`cdsp`/`slpi`（modem 为 `auto_boot=false`），timer 20s 兜底 | ✅ |
| `modem-mnt.service` | 挂 modem(NON-HLOS) 到 `/mnt/mdmpart`，链 `image/modem_pr` | ✅ |
| `crux-kmsg-tap.service` / `dmesg-snap.service` / `power-snap.service` | 内核日志落盘 / dmesg 快照 / 电源状态快照 | ✅ |

`x50-*` 系列 15 个单元、`modem-mgr`、`tqftpserv-v3`、`crux-x50-poweroff` 在仓库里（原路径），无 `*.wants` 链接，默认不启动。

### 5.2 用户态程序（`overlay/usr/local/`）

- `bin/`：`npu`、`npuctl`、`npu-svc`、`hexagonrpcd`、`ssccli`、`sscregistrygen`、`rmtfs`、`tqftpserv`、`pd-mapper`、`crux-*.sh`、`uim` 等
- `sbin/`：`crux-ssc-registry-gen.sh`、`wait-dsp-ready.sh`、`crux-*`（时间/swap/UFS/充电/关机/子系统拉起）、`crux-sim-x50`
- `lib/`：`libhexagonrpc.so.0.5`、`libqrtr.so.1.2`
- `libexec/`：`hexagonrpc/chrecd`、`resources/resources-{adjust,kill,processes}`
- `share/`：`resources/resources.gresource`

### 5.3 内核模块（`modules/`）

| 模块 | 用途 |
|---|---|
| `msm_qmp.ko` | SM8150 QMP/QRTR 传输 |
| `npu_boot24.ko` | NPU 上电与启动序列 |
| `qcom_usb_vbus-regulator.ko` | typec 的 `vdd-vbus-supply` |

### 5.3.1 VA-API 硬解（`src/iris-vaapi/`）

| 项 | 值 |
|---|---|
| 源码 | `src/iris-vaapi/`（`make` 生成 `build/vpu_drv_video.so`） |
| 产物 | `overlay/usr/lib/aarch64-linux-gnu/dri/vpu_drv_video.so` |
| 环境 | `overlay/etc/environment.d/99-libva-vpu.conf` 设 `LIBVA_DRIVER_NAME=vpu` |
| 依赖 | 内核 `qcom_iris` + `/dev/video0`；`libva2`/`libva-drm2` |
| 支持 | H.264 CB/Main/High、HEVC Main/Main10、VP9 P0/P2（VLD） |

改动源码后重编并覆盖 overlay 里那份 `.so`，两端版本保持一致。

### 5.4 模块 / 内核配置

- `etc/modules-load.d/crux-wifi.conf`（`ath10k_snoc`）、`msm_qmp.conf`、`crux-usb.conf`
- `etc/modprobe.d/99-qcom-iris.conf`（`cached_capture=1`）、`blacklist-crux-video.conf`
- `etc/udev/rules.d/99-qcom-iris-dmaheap.rules`（`dma_heap/system` 0666）
- `etc/sysctl.d/90-ufs-writeback.conf`、`99-printk-quiet.conf`

### 5.5 音频

| 文件 | 作用 |
|---|---|
| `usr/share/alsa/ucm2/conf.d/sm8150/sm8150.conf` | UCM 入口（Syntax 3，`SectionUseCase."HiFi"`） |
| `usr/share/alsa/ucm2/conf.d/sm8150/HiFi.conf` | `SectionVerb` 内写路由；`Speaker`（200，QUAT_MI2S→CS35L41）、`Earpiece`（100，SLIMBUS_0_RX→RX INT0→EAR） |
| `etc/wireplumber/wireplumber.conf.d/51-crux-fmt.conf` | `node.name = ~alsa_output.*` → S16LE / 48k / 2ch |
| `etc/wireplumber/wireplumber.conf.d/52-crux-noproaudio.conf` | 关闭 `pro-audio` profile |
| `usr/local/bin/crux-audio-route.sh` + `crux-audio-route.service` | 开机打开 BE mixer |

约束：ALSA 卡 id = UCM 目录名 `sm8150`（由 dts `&sound model` 末词决定）；UCM 用 Syntax 3 且路由写在 `SectionVerb` 的 `EnableSequence`；PipeWire 侧 S16_LE / 2ch / 48k。

### 5.6 drop-in

| 目标单元 | drop-in | 内容 |
|---|---|---|
| `crux-swap` / `crux-ufs-stable` / `crux-charger-init` / `crux-fastrpc-guard` / `crux-ssc-registry` | `zz-timeout.conf` | `TimeoutStartSec=120` |
| `crux-gpu-iface` / `crux-touch-watchdog` | `10-crux-fast-stop.conf` | `TimeoutStopSec=2s` + `KillMode=control-group` |

### 5.7 外挂 X50 / SIM

文件就位于 `etc/systemd/system/x50-*`、`usr/local/{bin,sbin}/x50-*`、`etc/udev/rules.d/{77-mm-x50-*,99-x50-nopm}`、`etc/modprobe.d/{x50-mhi,ipa_mhi_proxy}.conf`。

| 项 | 说明 |
|---|---|
| 默认 | 无 `*.wants` 链接，`build.sh` 的 UNITS 不列，开机不启动 |
| 开关 | `/etc/crux-sim.conf` 的 `SIM_X50_ENABLE`，默认 0 |
| 操作 | `crux-sim-x50 enable` / `disable` / `status`（只做 `systemctl enable`/`disable --now`） |

`x50-mhi.conf` / `ipa_mhi_proxy.conf` 只在 `modprobe.d` 备好参数，`insmod ipa_mhi_proxy` 在 `x50-modem-boot.sh` 内，不 enable 则无效果。

### 5.8 交换空间

| 组成 | 参数 | 默认 | 打开 |
|---|---|---|---|
| zram | `ZRAM_MB`（默认 0）、`ZRAM_PRIO`（默认 100） | 关 | `SWAP_ENABLE=1` + `ZRAM_MB=4096`，`systemctl restart crux-swap` |
| swapfile | `LROOT_SWAP=1`（需另一块 `PARTLABEL=linux-root`；`/` 本身是 linux-root 时跳过）、`LROOT_SWAP_MB`（默认 8192） | 关 | 同上 |

## 6. 已验证状态（2026-10-20 设备实测）

显示（`card0-DSI-1=connected`）、GPU、触摸（`fts`）、按键、UFS、`/vendor`+`/mnt/sys` 只读读取、WiFi（`ath10k_snoc`，`wlan0`）、四颗 remoteproc（slpi/modem/cdsp/adsp）全 `running`、rmtfs/tqftpserv/ModemManager/modem-mnt 常驻、NPU（`/dev/msm_npu` + `npu-svc`，InceptionV3 109 层 / 10.31 ms / 92.5%）、视频编解码（`/dev/video0/1`）、26 个 thermal zone、音频（Speaker + Earpiece 可切，`hw_params = S16_LE/2ch/48000`）。

## 7. 备注

- `npu-boot.service` 的模块路径为 `/usr/lib/modules/$(uname -r)/kernel/npu_boot24.ko`
- `npu-svc` 默认只开 unix socket；局域网调用设 `NPU_SVC_TCP=1`（TCP 5300）
- 服务顺序：`qrtr-ns` → `pd-mapper`/`tqftpserv` → `rmtfs`/`hexagonrpcd`
- `crux-swap` 默认不建 swap；改 `/etc/crux-swap.conf` 生效
- SIM/X50 默认不 enable
- 相机未适配
- 桌面与 Docker 由包清单提供（`sda37` 清单含 GNOME + gdm3、`docker.io`）

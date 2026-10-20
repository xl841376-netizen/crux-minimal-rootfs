# crux 最小 rootfs（Xiaomi Mi 9 Pro 5G / SM8150）

> 主线 Linux（7.3）跑这台机器用的**最小可开机 rootfs**：一份 Ubuntu 基础系统 + 本机适配层 + 各子系统要的用户态配套。
> 整理时间：**2026-10-20**（取自设备实际运行的 rootfs：Ubuntu 26.04.1 LTS `resolute`，内核 `7.3.0-rc5-crux73`）
> **本仓库不含可刷写的系统本体**：系统（Ubuntu 本体）请自己下官方的，本仓库只提供“装好系统之后要叠上去的那一层”。

---

## 1. 这份东西分成三层，别混着看

| 层 | 是什么 | 从哪来 | 在本仓库里？ |
|---|---|---|---|
| **L0 基础系统** | Ubuntu 26.04.1 aarch64 本体（systemd、udev、dbus、kmod、apt、openssh、sudo、python3…） | 官方/最小系统镜像 | ❌ 不含（要自己下 Ubuntu rootfs） |
| **L1 基础系统上的“必备包”** | 各子系统靠它们跑起来的通用软件包，见 §4 每行的“基础包”列 | `apt install` | ❌ 不含（`build.sh` 里有清单，或用 §3 装好后补装） |
| **L2 设备适配层** | 本仓库 `overlay/`：systemd 单元、设备脚本、udev 规则、modprobe 参数、sysctl、UCM、WirePlumber 规则 | 本机实测整理 | ✅ 全部在这里 |
| **L3 子系统专属用户态** | `npu`/`npuctl`/`npu-svc`、`hexagonrpcd` + `libhexagonrpc`/`libqrtr`、`rmtfs`/`tqftpserv`/`pd-mapper` 等**设备专用二进制** | 从设备/上游编出来的 | ✅ 在 `overlay/usr/local/` |
| — | 内核模块 | 内核源码树编译 | ✅ 在 `modules/` |

> 要点：**L0/L1 是“任何 Ubuntu 都有的东西”，L2/L3 才是“这台机器的东西”**。
> 换设备时只该换 L2/L3；升级系统只涉及 L0/L1。

### 1.1 基础包（L1）怎么最小化集成

不把 `.deb` 塞进仓库，而是给**分级清单 + 一个脚本**——仓库体积为零，装的时候一条命令。

| 档 | 装什么 | 包数（含依赖） | 下载 | 安装后 |
|---|---|---|---|---|
| `minimal` | 音频栈（`alsa-ucm-conf` / `alsa-utils` / `libasound2t64` / `pipewire`+`-pulse`+`-alsa` / `wireplumber`） | 166 | **41.9 MB** | 161 MB |
| **`standard`（推荐）** | minimal + 网络/SSH（`network-manager` / `wpasupplicant` / `rfkill` / `iw` / `openssh-server`）+ 基带用户态（`modemmanager` / `libqmi-utils` / `libmbim-utils`）+ `python3` / `sudo` / `e2fsprogs` / `dosfstools` | 239 | **63.9 MB** | 256 MB |
| `full` | standard + gstreamer 媒体栈 + `v4l-utils` | 486 | **945 MB** | 1775 MB |

> `full` 那约 880MB 的增量几乎全在 `gstreamer1.0-plugins-good/bad` 的编解码依赖里。
> **只想验证视频硬解不需要它**：`v4l2-ctl` 或 `mpv` 就够，`full` 只在做播放器/转码时才装。

三种用法：

```bash
# ① 在线装（推荐）：装完系统后一条命令
sudo ./deps/install-deps.sh standard
#    换国内镜像源：
#    MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports sudo -E ./deps/install-deps.sh standard

# ② 离线 deb 缓存：在有网的同架构机器上下载，再拷到目标机
./deps/fetch-debs.sh standard        # 产物在 deps/debs/*.deb + install-offline.sh
#    目标机执行： ./deps/debs/install-offline.sh

# ③ 完全预装：把 ①② 做进自制 rootfs 归档再压（仓库不提供这种大包）
```

`deps/lists/{minimal,standard,full}.list` 就是纯包清单，改它即可定制。

---

## 2. 仓库结构

| 路径 | 内容 |
|---|---|
| `overlay/` | **设备适配层 + 子系统专属用户态**，按 rootfs 绝对路径存放，直接覆盖到根即可 |
| `modules/` | 设备专用 out-of-tree 内核模块（装到 `/usr/lib/modules/<kver>/extra/`） |
| `build.sh` | 从 Ubuntu 最小系统重建（debootstrap → 套 overlay → 装模块 → 启用服务）。**只是备选路径**，正常装机用 §3 |
| `mkimage.sh` | **一键构建完整 rootfs 包**（debootstrap → 装包 → overlay → 固件/模块 → 打包） |
| `tools/fetch-firmware.sh` | 从在役设备拉固件与内核模块（厂商专有文件，不进仓库） |
| `deps/` | **L1 基础包的分级清单**（`lists/{minimal,standard,full}.list`）+ 在线安装脚本 + 离线 deb 打包脚本 |
| `MANIFEST.txt` | 全部文件的路径 + sha256 |

**有意排除**：任何私钥（`/root/.ssh/*`、SSH 主机密钥）、无线凭据（NM profile 里的 PSK）、`/root` 私人材料、日志、固件二进制（`/lib/firmware` 太大，装机后从设备/刷机包取）。

---

## 3. 怎么装

两种方式，**推荐第一种**：

| 方式 | 你要做的事 | 适合 |
|---|---|---|
| **A. 用现成的包** | 下载一个 `tar.zst`，解压到新根分区，改 grub 的 `root=` | 想尽快开机 |
| B. 自己构建 | `./tools/fetch-firmware.sh` + `sudo ./mkimage.sh` | 想改包清单 / 追新版 |

> **这个包不含内核。** 内核 `Image`、设备树 `.dtb`、`initramfs.cpio.gz` 和 `grub.cfg`
> 是另外单独写到 **ESP（eFI 分区）** 的，由 grub 引导。包里只有"根分区该有的东西"。

---

### 3.1 方式 A：用现成的包（最快）

**Release 页面**下载两个文件：

当前最新（**`rootfs-20261020-0652`**，云端自动构建，2026-10-20）：

| 文件 | 说明 |
|---|---|
| `crux-rootfs-resolute-arm64-20261020.tar.zst` | 1.43 GB（解压后约 5.2 GB + 固件 417 MB + 模块 361 MB） |
| `SHA256SUMS` | 校验用（`sha256sum -c SHA256SUMS`） |

> 这一版由 **GitHub Actions 自己构建并发布**（`rootfs-build.yml`，`package_set=sda37`），
> 产物与在役机 sda37 **逐项对齐**：
>
> - 包集 = `deps/lists/sda37.list`（1666 个包，取自 sda37 的 `dpkg --get-selections`），
>   含完整 **GNOME 桌面 + gdm3**、`ubuntu-desktop-minimal`、`ibus-libpinyin`、`fonts-noto-cjk`、
>   `language-pack-zh-hans`、`docker.io`、`build-essential`；CI 实际安装 1666/1666，无缺失
> - 本地原生二进制与库已进 overlay：`/usr/local/bin` 的 12 个 ELF（`tqftpserv`、`pd-mapper`、
>   `rmtfs`、`hexagonrpcd`、`qmisd`、`mdm_helper_native` …）+ `/usr/local/lib`
>   （`libqrtr.so.1.2`、`libhexagonrpc.so.0.5`），修掉 `tqftpserv` 缺 `libqrtr.so.1`
> - 默认目标 `graphical.target`，`display-manager.service -> gdm3.service`，`gdm3` 已 enable
> - 自动创建用户 `crux`（uid 1000，组 sudo,audio,video,input,render,netdev,dialout,lp,tty，
>   初始密码 `crux`），时区 Asia/Shanghai，locale zh_CN.UTF-8，ibus 输入法环境变量
> - 内核模块 1652 个，`extra/` 已归一为 0；fstab 按 `PARTLABEL=linux-root`
> - **不含任何 WiFi 密码 / 私钥**（CI 会校验包内 `etc/netplan/*.yaml` 数量必须为 0）

> 想在写盘时就把自己的 WiFi 认证数据带进去：用 `--private <目录>`（见 §3.3），
> 或写盘后 `cp -a` 到 `/etc/netplan/` 并 `chmod 600`。

```bash
# ① 建一个根分区（默认标签 linux-root，fstab 里就是按这个找的；
#    若用别的标签，加 --root-label 或写盘后改 /etc/fstab）
sudo sgdisk -n 0:0:+24G -t 0:8300 -c 0:linux-root /dev/sda
sudo mkfs.ext4 -L linux-root /dev/sda38        # 分区号以 sgdisk 输出为准

# ② 解压 = 写系统（这就是全部）
sudo mount /dev/sda38 /mnt
sudo tar --zstd -xpf crux-rootfs-resolute-arm64-20261020.tar.zst -C /mnt
sudo sync && sudo umount /mnt

# ③ 让 grub 指向这个分区
sudo blkid -s UUID -o value /dev/sda38         # 记下 UUID
```

ESP 上的 `EFI/crux/grub.cfg` 里把 `root=` 改成这个 UUID（其余沿用现有条目）：

```
linux (hd0,gpt35)/EFI/crux/Image74 root=UUID=<上面那个UUID> rootwait rw ...
```

ESP 那边需要已有：`Image`（内核）、`*.dtb`（设备树）、`initramfs.cpio.gz`、`grub.cfg`。
这些**不在本包里**，是另一件事。

**首次开机后**：

```bash
passwd                      # root 默认密码 root，务必改掉
ls /sys/class/net            # wlan0 应在；NetworkManager 起来后 nmcli 连网
speaker-test -t sine -c 2   # 出声验证（前台跑会卡住会话，用 setsid nohup）
```

---

#### 3.1.1 三种写入通路（挑一种）

| 通路 | 前提 | 怎么做 |
|---|---|---|
| **① 在已运行的 Linux 里写** | 手上已有一台能起来的 crux/或任何 Linux | `mount /dev/sdaXX /mnt` → `tar --zstd -xpf … -C /mnt` |
| **② UMS 大容量模式（从 PC 写）** | Android 已 root，或进了 recovery | 设备把整块 UFS 暴露成一个 U 盘，PC 当成普通磁盘分区/写 |
| **③ dd 整盘镜像** | 手上有 `.img` | `dd if=xxx.img of=/dev/sdX bs=4M status=progress` |

**② UMS 的具体操作**（推荐 PC 侧操作，避免误碰 Android 分区）：

```bash
# 设备侧（Android，需 root；把整块 sda 暴露成 U 盘）
modprobe g_mass_storage file=/dev/block/sda removable=1
# 或者只暴露某一块：file=/dev/block/by-name/linux-root

# PC 侧（会多出一个 /dev/sdX，先确认大小对得上！）
lsblk
sudo sgdisk -n 0:0:+24G -t 0:8300 -c 0:linux-root /dev/sdX
sudo mkfs.ext4 -L linux-root /dev/sdX38
sudo mount /dev/sdX38 /mnt && sudo tar --zstd -xpf crux-rootfs-*.tar.zst -C /mnt
sudo umount /mnt
# 收尾（设备侧）
rmmod g_mass_storage
```

> **UMS 模式下 PC 看到的是整块盘**，`sgdisk` 改的是设备真实 GPT，所以务必：
> 只做「追加新分区」，**不要删/改 sda1–sda34**（Android 的 boot/dtbo/vendor/system/userdata 全在那里）。

**③ 与 Android 共存的前提**

| 项 | 说明 |
|---|---|
| 分区加密 | Android 的 `userdata`（sda34）若是 FBE/FDE 加密，**Linux 不能直接挂它**。共存 = 给 Linux **单独一个新分区**，不去碰 userdata。不需要解密，也不需要格式化 userdata |
| 需要"解除加密"的场景 | 只有当你想让 Linux 直接读写 Android 的 /data 时才有意义——本方案**不需要** |
| 千万别动的分区 | sda1–sda34（含 `super`/`userdata`/`vbmeta`/`boot`）；只往后面追加 `sda38+` |
| ESP | Linux 的内核/dtb/initramfs 放在 **ESP（sda35, FAT32, 512M）** 的 `EFI/crux/` 下，和 Android 互不影响 |
| AVB/dm-verity | 新增分区不影响它们；但不要改 `vbmeta`，也不要动 vendor/system 分区的只读属性 |
| 回退 | 想彻底回 Android：`sgdisk -d <新分区号>` 删掉 Linux 分区，把 ESP 里 `EFI/crux/` 删掉即可，Android 分区一个字节都没动过 |

### 3.2 方式 B：自己构建

```bash
# 1) 从在役设备拉固件与内核模块（厂商专有文件，不在仓库里）
./tools/fetch-firmware.sh root@192.168.1.240 ./fw
#    → ./fw/firmware/（约 417MB）  ./fw/modules/（约 363MB）

# 2) 构建（约 10 分钟，需要联网 + root）
sudo ./mkimage.sh /root/out --fw-dir ./fw
#    可调：--level minimal|standard|full   --suite resolute   --mirror <国内镜像>
#          --kver 7.3.0-rc5-crux73         --no-fw（只出干净系统+适配层）
```

产物同样是 `crux-rootfs-<suite>-arm64-<日期>.tar.zst` + `SHA256SUMS`，装法同 3.1。

`mkimage.sh` 干的事：`debootstrap minbase` → 按 `deps/lists/<level>.list` 装包 →
套 `overlay/` → 放固件和模块 → 写 `fstab`/`hostname`/root 密码 → `systemctl --root` 启用单元 → 打包。

---

### 3.3 一定要对上的三件事

1. **`/etc/fstab`**：`PARTLABEL=linux-root26  /  ext4 ...`（分区标签改了就要同步改这里）
2. **grub 的 `root=`**：指向上面的分区 UUID
3. **`/lib/modules/` 的版本号**要和 ESP 上那个内核的 `uname -r` 一致，否则模块全不加载
   （包里是 `7.3.0-rc5-crux73`；用别的内核就在构建时加 `--kver <版本>`）

---

## 4. 各子系统的配套（基础包 + 本机适配 + 状态）

“基础包”= L1，`apt` 装；“适配”= 本仓库 overlay 提供。

| 子系统 | 基础包（L1） | 本包提供的适配（L2/L3） | 机内其它需要 | 状态 |
|---|---|---|---|---|
| **显示 / GPU** | `mesa-*`、`libdrm-*`、`libgl1`、`libvulkan1` | `crux-display/te-sync`（内核侧）、`crux-gpu-iface.service`（把 GPU 统计暴露为标准 DRM 接口） | 固件 `qcom/a640_gmu.bin`、`qcom/a630_sqe.fw`、`a640_zap.mbn`（内核内嵌或 `/lib/firmware`） | ✅ 可用 |
| **触摸** | `libinput`、桌面栈 | `crux-touch-watchdog.service`（周期体检 + 自恢复） | 固件 `ftm5_fw.ftb`；`fts` 驱动 | ✅ 可用 |
| **UFS 存储** | `e2fsprogs`、`dosfstools` | `crux-ufs-stable.service`（标准 sysfs：`auto_hibern8=0`、LUN `power/control=on`）+ `ufs-nopm.service`（QCOM 私有 `rpm_lvl`/`clkgate_enable`/`clkscale_enable=0`）+ `90-ufs-writeback.conf` | — | ✅ 可用 |
| **WiFi（WCN3990）** | `network-manager`、`wpasupplicant`、`rfkill`、`iw` | `modules-load.d/crux-wifi.conf`（`ath10k_snoc`）、`ath10k` 日志降级 | 固件 `ath10k/WCN3990/hw1.0/*` + `qcom/sm8150/xiaomi/crux/wlanmdsp.mbn`；`regulatory.db`；`cfg80211.ieee80211_regdom=CN` | ✅ 可用（有自复位噪声，见 §6） |
| **音频** | `alsa-ucm-conf`、`alsa-utils`、`libasound2t64`、`pipewire`+`pipewire-pulse`+`pipewire-alsa`、`wireplumber` | `ucm2/conf.d/sm8150/{sm8150,HiFi}.conf`、`wireplumber.conf.d/{51-crux-fmt,52-crux-noproaudio}.conf`、`crux-audio-route.service` | 内核 dts `&sound { model = "… sm8150" }`（决定卡 id）、ADSP 起来（`adsp.mbn`） | ✅ 可用（Speaker + Earpiece） |
| **NPU** | `python3` | `npu`、`npuctl`、`npu-svc`、`npu-boot.service`、`npu-svc.service`、模块 `msm_qmp.ko`、`npu_boot24.ko`、`modules-load.d/msm_qmp.conf` | 固件 `npu.mdt`/`npu.b*`；`/dev/msm_npu` | ✅ 可用（InceptionV3 已跑通） |
| **传感器（SSC/SLPI）** | `python3` | `hexagonrpcd` + `libhexagonrpc.so.0.5`、`libqrtr.so.1.2`、`chrecd`、`resources*`、`ssccli`、`sscregistrygen`、`crux-ssc-registry.service`、`crux-fastrpc-guard.service`、`crux-sensor-adapt.service`、`wait-dsp-ready.sh` | 固件 `slpi.mbn`；`/dev/fastrpc-*` | ✅ 可用 |
| **视频编解码（iris/VPU）** | `gstreamer1.0-*`、`v4l-utils` | `iris-vpu.service`、`99-qcom-iris-dmaheap.rules`（`dma_heap/system` 0666，Chrome 硬解需要）、`modprobe.d/99-qcom-iris.conf`（`cached_capture=1`）、`blacklist-crux-video.conf`（说明性） | 固件 `venus.mbn` | ✅ 可用 |
| **内置基带（mpss）** | `modemmanager`、`libqmi-utils`、`libmbim-utils` | `rmtfs`/`tqftpserv`/`pd-mapper`（L3 二进制 + 单元）、`modem-mnt.service`（挂 modem 分区、链 `image/modem_pr`）、`qcom-subsys-start.service/.timer`（拉 mpss/adsp/cdsp/slpi） | 固件 `qcom/sm8150/xiaomi/crux/{modem,adsp,cdsp,slpi}.mbn`；分区 `modemst1/2`、`fsc`、`fsg`（EFS） | ⚠️ 子系统能起、ModemManager 常驻；注册/数据未验证 |
| **USB（ECM/ACM）** | `usbutils`、`libusb` | `usb-gadget-acm.service`、`usb-align.service`（ARP/路由对齐） | 供电 `qcom_usb_vbus-regulator.ko`（在 `modules/`）、`modules-load.d/crux-usb.conf` | ✅ 可用 |
| **电源 / 充电 / 关机链** | `systemd` | `crux-charger-init.service`、`crux-markshutdown.service`、`crux-crashsave.service`、`dmesg-snap.service`、`power-snap.service`、`crux-kmsg-tap.service`、`99-printk-quiet.conf` | `pm8150b` charger/fuel-gauge 驱动 | ✅ 可用 |
| **交换空间** | — | `crux-swap.service`：`/etc/crux-swap.conf` 全参数化，`SWAP_ENABLE=0` **默认全部关闭**（zram 与 swapfile 都不建，并将已有 swap `swapoff -a`） | — | ⛔ 默认无 swap |
| **外挂 X50 / SIM** | — | `x50-*` 单元与程序**按原路径就位但默认不 enable**（见 §5.7），开关 `crux-sim-x50` | 固件 `qcom/sdx50m/*` | ⛔ 未跑通，默认不启用 |
| **相机** | — | — | — | ⛔ **未适配，本包不涉及** |

---

## 5. 适配层清单

### 5.1 服务（systemd 单元）

| 单元 | 作用 | 开机启用 |
|---|---|---|
| `rmtfs.service` | Qualcomm remotefs（EFS 读写） | ✅ |
| `tqftpserv.service` | QRTR TFTP（给 DSP/模组发固件） | ✅ |
| `pd-mapper.service` | 保护域映射 | ✅ |
| `hexagonrpcd-sdsp.service` | 传感器 DSP 的 FastRPC 文件服务 | ✅ |
| `crux-ssc-registry.service` | 生成 SSC 传感器 registry 文件树 | ✅ |
| `iris-vpu.service` | 加载 `videocc-sm8150`/`system_heap`/`cma_heap`/`qcom_iris` | ✅ |
| `npu-svc.service` | NPU 常驻服务（`/run/npu.sock`） | ✅ |
| `npu-boot.service` | NPU PAS 开机序列（`insmod npu_boot24.ko`） | ⛔ 默认不启用 |
| `crux-fastrpc-guard.service` | FastRPC 守护 | ✅ |
| `crux-touch-watchdog.service` | 触摸 IC 体检 + 自恢复 | ✅ |
| `crux-gpu-iface.service` | GPU 统计暴露为标准 DRM 接口 | — |
| `crux-sensor-adapt.service` | hwmon → `cpu-thermal` 等标准名 | — |
| `usb-gadget-acm.service` / `usb-align.service` | USB ECM gadget / ARP 对齐 | ✅ |
| `qsee-supplicant.service` / `qsee-app-loader@.service` | Qualcomm TEE 服务 / 应用加载器 | ✅ |
| `crux-audio-route.service` | 开机把播放路由固定到扬声器通路（`QUAT_MI2S_RX Audio Mixer MultiMedia1=on`）；FE 没有 BE 时 open 会 EINVAL | ✅ |
| `crux-time-sync.service` + `.timer` | 开机校时 + 每 6 小时兜底（本机 **RTC 无驱动**，时间会错到 30 天前，apt 立刻报 `Release not valid yet`） | ✅ |
| `crux-swap.service` | **默认全部关闭**（`SWAP_ENABLE=0`：不建 zram、不建 swapfile）。需要时在 `/etc/crux-swap.conf` 打开总闸并按需设 `ZRAM_MB` / `LROOT_SWAP` | ⛔ |
| `crux-ufs-stable.service` / `ufs-nopm.service` | UFS 两种加固（标准 sysfs / QCOM 私有 sysfs），**互补不重复** | ✅ |
| `crux-charger-init.service` | 开机设置 SMB5 充电电流 ICHG | ✅ |
| `crux-crashsave.service` | 上一轮 dmesg 尾部写到 ESP（`LASTBOOT.TXT` / `CRASH.TXT`） | ✅ |
| `crux-markshutdown.service` | 打“干净关机”标记（`WantedBy=shutdown.target`） | ✅ |
| `qcom-subsys-start.service` + `.timer` | 拉 `mpss`/`adsp`/`cdsp`/`slpi`（modem 是 `auto_boot=false`），timer 20s 兜底 | ✅ |
| `modem-mnt.service` | 挂 modem(NON-HLOS) 分区到 `/mnt/mdmpart`，链 `image/modem_pr` | ✅ |
| `crux-kmsg-tap.service` / `dmesg-snap.service` / `power-snap.service` | 内核日志落盘 / dmesg 快照 / 电源状态快照 | ✅ |

> 注：`x50-*` 系列 15 个单元、`modem-mgr`、`tqftpserv-v3`、`crux-x50-poweroff` 也在仓库里（原路径），但**默认一个都不 enable**，见 §5.7。

### 5.2 用户态程序（`overlay/usr/local/`）

- `bin/`：`npu`、`npuctl`、`npu-svc`、`hexagonrpcd`、`ssccli`、`sscregistrygen`、`rmtfs`、`tqftpserv`、`pd-mapper`、`crux-*.sh`（音频路由/触摸看护/GPU 接口/传感器适配/USB gadget）/ `uim` 等
- `sbin/`：`crux-ssc-registry-gen.sh`、`wait-dsp-ready.sh`、`crux-*`（时间/swap/UFS/充电/关机/子系统拉起）、`crux-sim-x50`（SIM 开关）
- `lib/`：`libhexagonrpc.so.0.5`、`libqrtr.so.1.2`
- `libexec/`：`hexagonrpc/chrecd`、`resources/resources-{adjust,kill,processes}`
- `share/`：`resources/resources.gresource`

### 5.3 内核模块（`modules/`）

| 模块 | 用途 |
|---|---|
| `msm_qmp.ko` | SM8150 QMP/QRTR 传输配套 |
| `npu_boot24.ko` | NPU 上电与启动序列 |
| `qcom_usb_vbus-regulator.ko` | typec 的 `vdd-vbus-supply`（原 rootfs 里就缺这个，缺了 USB 起不来） |

### 5.4 模块/内核相关配置

- `etc/modules-load.d/crux-wifi.conf`（`ath10k_snoc`）、`msm_qmp.conf`、`crux-usb.conf`
- `etc/modprobe.d/99-qcom-iris.conf`（`cached_capture=1`）、`blacklist-crux-video.conf`
- `etc/udev/rules.d/99-qcom-iris-dmaheap.rules`（`dma_heap/system` 0666）
- `etc/sysctl.d/90-ufs-writeback.conf`、`99-printk-quiet.conf`

### 5.5 音频（2026-10-20 打通，双设备）

| 文件 | 作用 |
|---|---|
| `usr/share/alsa/ucm2/conf.d/sm8150/sm8150.conf` | UCM 入口（**Syntax 3**，`SectionUseCase."HiFi"`） |
| `usr/share/alsa/ucm2/conf.d/sm8150/HiFi.conf` | `SectionVerb` 里写播放路由；`Speaker`（200，QUAT_MI2S→CS35L41）、`Earpiece`（100，SLIMBUS_0_RX→RX INT0→EAR） |
| `etc/wireplumber/wireplumber.conf.d/51-crux-fmt.conf` | `node.name = ~alsa_output.*` → 强制 **S16LE / 48k / 2ch** |
| `etc/wireplumber/wireplumber.conf.d/52-crux-noproaudio.conf` | 关掉 `pro-audio` profile（否则 ACP 默认选它，8ch 无声） |
| `usr/local/bin/crux-audio-route.sh` + `crux-audio-route.service` | 开机打开 BE mixer 做保险 |

**出声要同时满足三条，缺一条都是静默失败**（FE 显示 RUNNING、dmesg 无报错、就是没声音）：

1. **ALSA 卡 id 必须等于 UCM 目录名 `sm8150`。** 卡 id 由 dts `&sound { model = "…" }` 的**最后一个词**决定（`sound/core/init.c: retrieve_id_from_card_name()`）；`ucm.conf` 里 `Define.V2Name ""` 关闭按卡名查找，只按驱动名查 `conf.d/`。
2. **UCM 必须 Syntax 3、路由写在 `SectionVerb` 的 `EnableSequence`。** 写成 Syntax 4 + `SectionPCM` 会让 ACP 的逐 PCM 探测失败（`_ucmXXXX.hw:0` 打不开）。
3. **PipeWire 侧必须 S16_LE / 2ch / 48k。** 默认会以 `S24_LE / 8ch` 打开 —— 全程无声且不报错。

排查口诀：先看 `dmesg | grep "no backend DAIs enabled"`（BE 没开），再看 `hw_params` 是不是 `S24_LE / 8ch`。

### 5.6 drop-in 修正（`*.service.d/*.conf`）

| 目标单元 | drop-in | 内容 |
|---|---|---|
| `crux-swap` / `crux-ufs-stable` / `crux-charger-init` / `crux-fastrpc-guard` / `crux-ssc-registry` | `zz-timeout.conf` | `TimeoutStartSec=120` |
| `crux-gpu-iface` / `crux-touch-watchdog` | `10-crux-fast-stop.conf` | `TimeoutStopSec=2s` + `KillMode=control-group` |

少了这些，关机时会白等满 90 秒。

### 5.7 外挂 X50 / SIM —— 原样就位，默认不启动

这套是**本机专用**的，不是通用镜像，所以文件就按原样待在系统路径里（`etc/systemd/system/x50-*`、`usr/local/{bin,sbin}/x50-*`、`etc/udev/rules.d/{77-mm-x50-*,99-x50-nopm}`、`etc/modprobe.d/{x50-mhi,ipa_mhi_proxy}.conf`）。开关只决定**要不要开机起来**：

| 项 | 说明 |
|---|---|
| 默认状态 | 文件在，但**没有任何 `*.wants` 链接、`build.sh` 的 UNITS 里也不列** → 开机不启动 |
| 开关 | `/etc/crux-sim.conf` 的 `SIM_X50_ENABLE`，**默认 0** |
| 打开 / 关闭 / 查看 | `crux-sim-x50 enable` / `disable` / `status`（只做 `systemctl enable` / `disable --now`，不搬文件） |

**为什么默认不启动**：X50 那条链（MHI → IPA → QMI → UIM provisioning session `0x38`）还没跑通，曾出现过“做 QMI 操作把整机拖死”。默认参与基带的只有**内置四个子系统**；`qcom-subsys-start.service` 里也已去掉 `x50-rfs-persist` 依赖。

> `x50-mhi.conf` / `ipa_mhi_proxy.conf` 在 `modprobe.d` 只是“参数就位”，默认没有任何路径去 `modprobe ipa_mhi_proxy`（那条 `insmod` 在 `x50-modem-boot.sh` 里），不 enable 时无效果。

### 5.8 交换空间

| 组成 | 落点 | 默认 | 打开方式 |
|---|---|---|---|
| zram（内存压缩） | `ZRAM_MB`（MiB，**默认 0 = 不建**），`ZRAM_PRIO`（默认 100） | ⛔ 默认关 | `SWAP_ENABLE=1` + `ZRAM_MB=4096`，`systemctl restart crux-swap` |
| 磁盘 swapfile | `LROOT_SWAP=1`（需另一块 `PARTLABEL=linux-root`；若 `/` 本身就叫 linux-root 会自动跳过），`LROOT_SWAP_MB`（默认 8192） | ⛔ 默认关 | 同左设置 + `systemctl restart crux-swap` |

---

## 6. 已验证状态（2026-10-20 09:30 设备实测）

显示（`card0-DSI-1=connected`）、GPU、触摸（`fts`）、按键、UFS、`/vendor`+`/mnt/sys` 只读读取、
WiFi（`ath10k_snoc`，`wlan0` 静态 `192.168.1.240`）、四颗 remoteproc（slpi/modem/cdsp/adsp）全 `running`、
rmtfs/tqftpserv/ModemManager/modem-mnt 常驻、**NPU（`/dev/msm_npu` + `npu-svc`，InceptionV3 109 层 / 10.31 ms / 92.5%）**、
视频编解码（`/dev/video0/1`）、26 个 thermal zone、
**音频（Speaker + Earpiece 双设备可切、已实听出声，`hw_params = S16_LE/2ch/48000`）**均已就位。

---

## 7. 注意

- `npu-boot.service` 指向 `/usr/lib/modules/$(uname -r)/extra/npu_boot24.ko`（不再依赖 `/root`）
- `npu-svc` 默认只开 unix socket；需要局域网调用设 `NPU_SVC_TCP=1`（TCP 5300）
- 服务顺序：`qrtr-ns` → `pd-mapper`/`tqftpserv` → `rmtfs`/`hexagonrpcd`
- `crux-swap` 默认不开任何 swap（zram 与 swapfile 全关）；需要时改 `/etc/crux-swap.conf`（见上表），不依赖任何额外分区。
- SIM/X50 默认不 enable；要试就 `crux-sim-x50 enable`，出问题 `crux-sim-x50 disable`
- **相机未适配**，本包不含任何相机相关配置
- 本包只是**适配层 + 子系统用户态**；桌面（KDE/GNOME）、Docker 等按需自行安装

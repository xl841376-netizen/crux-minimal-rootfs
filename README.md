# crux 最小 rootfs（设备适配层）

> **Xiaomi Mi 9 Pro 5G（crux / SM8150）** 主线 Linux 用的**最小 rootfs 包**：
> 一份 Ubuntu 基础系统 + 针对该设备适配过的**全部用户态文件、systemd 服务和内核模块**。
>
> 导出时间：**2026-10-20**（取自设备当前实际运行的 rootfs：Ubuntu 26.04.1，内核 7.3.0-rc5-crux73）

---

## 1. 这个仓库是什么

| 路径 | 内容 |
|---|---|
| `overlay/` | **设备适配层**：按 rootfs 绝对路径存放（`usr/…`、`etc/…`），直接覆盖到根即可 |
| `modules/` | 设备专用 out-of-tree 内核模块（安装时放进 `/usr/lib/modules/<kver>/extra/`） |
| `build.sh` | 从 Ubuntu 最小系统重建完整 rootfs：debootstrap → 套用 overlay → 装模块 → 启用服务 |
| `MANIFEST.txt` | 全部文件的路径 + sha256 |

**不包含**（有意排除）：任何私钥（`/root/.ssh/*`、SSH 主机密钥）、无线网络凭据（NM/netplan 里的 PSK）、`/root` 私人材料、日志、Docker 镜像、桌面套件本体（KDE 属于基础系统，不在适配层里）。

---

## 2. 适配层清单

### 2.1 服务（systemd 单元，`overlay/etc/systemd/system/`）

| 单元 | 作用 | 开机启用 |
|---|---|---|
| `rmtfs.service` | Qualcomm remotefs（EFS 读写，模组固件/NV） | ✅ |
| `tqftpserv.service` | QRTR TFTP 服务（给 DSP/模组发固件） | ✅ |
| `pd-mapper.service` | Qualcomm PD Mapper（保护域映射） | ✅ |
| `hexagonrpcd-sdsp.service` | 传感器 DSP 的 FastRPC 文件服务（SLPI/SDSP） | ✅ |
| `crux-ssc-registry.service` | 生成 SSC 传感器 registry 文件树（hexagonrpcd 用） | ✅ |
| `iris-vpu.service` | 加载 `videocc-sm8150`/`system_heap`/`cma_heap`/`qcom_iris`（VPU 解码） | ✅ |
| `npu-svc.service` | NPU 常驻服务（unix socket `/run/npu.sock`；TCP 5300 需 `NPU_SVC_TCP=1`） | ✅ |
| `npu-boot.service` | NPU PAS 开机序列（insmod `npu_boot24.ko`） | ⛔ 默认不启用 |
| `crux-fastrpc-guard.service` | FastRPC 守护 | ✅ |
| `crux-touch-watchdog.service` | 触摸 IC 周期健康检查 + 自恢复 | ✅ |
| `crux-gpu-iface.service` | 暴露 GPU 统计为标准 DRM 接口 | — |
| `crux-sensor-adapt.service` | 把 hwmon 适配成 `cpu-thermal` 等标准名 | — |
| `usb-gadget-acm.service` / `usb-align.service` | USB ECM 网卡 gadget + ARP 对齐 | ✅ |
| `qsee-supplicant.service` / `qsee-app-loader@.service` | Qualcomm TEE 常驻服务 / 应用加载器 | ✅ |
| `crux-audio-route.service` | 开机把播放路由固定到扬声器通路（`QUAT_MI2S_RX Audio Mixer MultiMedia1=on`）；ASoC FE 没有 BE 时 open 会直接 EINVAL | ✅ |
| `crux-time-sync.service` + `crux-time-sync.timer` | 开机校时 + 每 6 小时兜底（本机 **RTC 无驱动**，时间会错到 30 天前，apt 立刻报 Release not valid yet） | ✅ |
| `crux-swap.service` | zram 4G（zstd，优先级 100）**默认启用**；`/mnt/lroot/swapfile` 8G 由 `/etc/crux-swap.conf` 的 `LROOT_SWAP` 控制，**默认关闭** | ✅ |
| `crux-ufs-stable.service` | 标准 sysfs 加固：`auto_hibern8=0`、`clkgate_delay_ms=1000`、各 LUN `power/control=on`（防链路 -110、关机跳过 SYNCHRONIZE CACHE） | ✅ |
| `ufs-nopm.service` | QCOM 私有低功耗开关：`rpm_lvl=0`、`clkgate_enable=0`、`clkscale_enable=0`（与上一条**互补不重复**） | ✅ |
| `crux-charger-init.service` | 开机设置 SMB5 充电电流 ICHG | ✅ |
| `crux-crashsave.service` | 把上一轮 dmesg 尾部写到 ESP（`EFI/crux/LASTBOOT.TXT`、非正常关机时额外 `CRASH.TXT`） | ✅ |
| `crux-markshutdown.service` | 打“干净关机”标记（`WantedBy=shutdown.target`） | ✅ |
| `qcom-subsys-start.service` + `.timer` | 拉 **mpss / cdsp / slpi** 三个远端子系统 + adsp（内置，不自动 boot）；timer 在开机 20s 兜底 | ✅ |
| `modem-mnt.service` | 把 modem(NON-HLOS) 分区只读挂到 `/mnt/mdmpart`，并把 `image/modem_pr` 链到固件目录（tqftpserv 用） | ✅ |
| `crux-kmsg-tap.service` / `dmesg-snap.service` / `power-snap.service` | 内核日志落盘 / dmesg 尾部快照 / 电源状态快照（全是排障用，常驻） | ✅ |
| `/etc/crux-swap.conf` | 交换空间开关（不是 unit）：`LROOT_SWAP=0` 默认只 zram；`=1` 才在 `/mnt/lroot` 上建 8G swapfile | — |
| `/usr/local/sbin/crux-sim-x50` + `/etc/crux-sim.conf` | SIM/X50 开关（不是 unit）：整套外挂 X50 的东西放在 `/opt/crux/sim-x50/`，**默认不安装**；`enable` 才铺回系统路径 | — |

### 2.2 用户态程序（`overlay/usr/local/`）

- `bin/`：`npu`、`npuctl`、`npu-svc`（NPU 工具链与常驻服务）、`hexagonrpcd`、`ssccli`、`sscregistrygen`（传感器 DSP）、`rmtfs`、`tqftpserv`、`pd-mapper`（模组/DSP 基础服务）、`crux-*` 一组适配脚本（触摸看护、GPU 接口、传感器适配、USB gadget/对齐）
- `sbin/`：`crux-ssc-registry-gen.sh`、`wait-dsp-ready.sh`
- `lib/`：`libhexagonrpc.so.0.5`、`libqrtr.so.1.2`（FastRPC / QRTR 用户态库）
- `libexec/`：`hexagonrpc/chrecd`、`resources/resources-{adjust,kill,processes}`
- `share/`：`resources/resources.gresource`

### 2.3 内核模块（`modules/`）

| 模块 | 用途 |
|---|---|
| `msm_qmp.ko` | SM8150 QMP/QRTR 传输配套 |
| `npu_boot24.ko` | NPU 上电与启动序列（Android-golden PAS 流程） |

### 2.4 模块/内核相关配置

- `etc/modules-load.d/crux-wifi.conf` → 开机加载 `ath10k_snoc`（WCN3990）
- `etc/modules-load.d/msm_qmp.conf` → `msm_qmp`
- `etc/modprobe.d/99-qcom-iris.conf`、`etc/modprobe.d/blacklist-crux-video.conf`
- `etc/udev/rules.d/99-qcom-iris-dmaheap.rules` → `dma_heap/system` 权限 0666（Chrome 的 VA-API 解码需要，否则回退软解）
- `etc/sysctl.d/90-ufs-writeback.conf`、`etc/sysctl.d/99-printk-quiet.conf`（dirty 写回参数 / 控制台只留 warning 以上）

### 2.5 音频（2026-10-20 打通，双设备）

| 文件 | 作用 |
|---|---|
| `usr/share/alsa/ucm2/conf.d/sm8150/sm8150.conf` | UCM 入口，**Syntax 3**，`SectionUseCase."HiFi"` |
| `usr/share/alsa/ucm2/conf.d/sm8150/HiFi.conf` | `SectionVerb` 里写播放路由；`Speaker`（优先级 200，QUAT_MI2S→CS35L41）、`Earpiece`（优先级 100，SLIMBUS_0_RX→RX INT0→EAR） |
| `etc/wireplumber/wireplumber.conf.d/51-crux-fmt.conf` | `node.name = ~alsa_output.*` → 强制 **S16LE / 48k / 2ch** |
| `etc/wireplumber/wireplumber.conf.d/52-crux-noproaudio.conf` | 关掉 `pro-audio` profile（否则 ACP 默认选它，8ch 无声） |
| `usr/local/bin/crux-audio-route.sh` + `crux-audio-route.service` | 开机把 BE mixer 打开做保险 |

**出声要同时满足三条，缺一条都是静默失败**（FE 显示 RUNNING、dmesg 无报错、就是没声音）：

1. **ALSA 卡 id 必须等于 UCM 目录名 `sm8150`。** 卡 id 由 dts `&sound { model = "…" }` 的**最后一个词**决定（`sound/core/init.c: retrieve_id_from_card_name()`）；而 `ucm.conf` 里 `Define.V2Name ""` 关闭了按卡名查找，只按驱动名查 `conf.d/`。
2. **UCM 必须是 Syntax 3、路由写在 `SectionVerb` 的 `EnableSequence`。** 写成 Syntax 4 + `SectionPCM` 会让 ACP 的逐 PCM 探测失败（`_ucmXXXX.hw:0` 打不开）。
3. **PipeWire 侧必须 S16_LE / 2ch / 48k。** 默认会以 `S24_LE / 8ch` 打开 —— 全程无声且不报错。

排查口诀：先看 `dmesg | grep "no backend DAIs enabled"`（说明 BE mixer 没开），再看 `hw_params` 是不是 `S24_LE / 8ch`。

### 2.6 drop-in 修正（`*.service.d/*.conf`）

| 目标单元 | drop-in | 内容 |
|---|---|---|
| `crux-swap` / `crux-ufs-stable` / `crux-charger-init` / `crux-fastrpc-guard` / `crux-ssc-registry` | `zz-timeout.conf` | `TimeoutStartSec=120` |
| `crux-gpu-iface` / `crux-touch-watchdog` | `10-crux-fast-stop.conf` | `TimeoutStopSec=2s` + `KillMode=control-group` |

少了这些，关机时会白等满 90 秒。

### 2.7 SIM / 外挂 X50（sdx50m）—— 整套保留，默认不安装

外挂 X50 基带（SIM 侧）那一套在设备上已存在但尚未定型，这里**原样保留**，但不参与默认启动：

| 项 | 说明 |
|---|---|
| 存放位置 | `overlay/opt/crux/sim-x50/` —— 按**系统绝对路径镜像**存放（`etc/systemd/system/…`、`usr/local/bin/…`），套用 overlay 后落在 `/opt/crux/sim-x50/`，**不生效** |
| 内容（70 个文件） | 15 个单元（`x50-modem-boot` / `x50-online` / `x50-qmi-l4` / `x50-qmi-l5` / `x50-card-monitor` / `x50-liveness` / `x50-efs-sync` / `x50-gen3` / `x50-pdc` / `x50-rfs-persist` / `x50-uim-prepare` / `x50-uim-activate` / `modem-mgr` / `tqftpserv-v3` / `crux-x50-poweroff`）+ 13 个 drop-in + 30 个程序（`x50-modem-loader`、`x50-qmi-*`、`x50-pdc-*`、`mdm_helper_native`、`mhi_efs_sync`、`pm_service_native`、`qmisd`、`q2*/q5*/qmi/qraw` 等调试脚本）+ 3 条 udev 规则（`77-mm-x50-efs` / `77-mm-x50-fusion` / `99-x50-nopm`）+ 2 个 modprobe 参数（`x50-mhi.conf` / `ipa_mhi_proxy.conf`） |
| 开关 | `/etc/crux-sim.conf` 的 `SIM_X50_ENABLE`（**默认 0**） |
| 打开 | `crux-sim-x50 enable` → 铺回系统路径 + `udevadm control --reload-rules` + `daemon-reload` + enable 全部单元；之后 `systemctl start x50-modem-boot` 或直接重启 |
| 关闭 | `crux-sim-x50 disable` → 停掉并 disable 全部单元 + 从系统路径移除文件（`/opt` 下副本保留） |
| 查看 | `crux-sim-x50 status` |

**默认不安装的原因**：X50 那条链（MHI → IPA → QMI → UIM provisioning session `0x38`）目前还没跑通，
曾出现过“做 QMI 操作把整机拖死”的情况。默认状态下参与基带的只有**内置四个子系统**
（`mpss` / `adsp` / `cdsp` / `slpi`，由 `qcom-subsys-start` 拉起），SIM 侧完全不介入——
`qcom-subsys-start.service` 里也已去掉 `x50-rfs-persist` 那个依赖。

---

## 3. 怎么用

### A. 套到已有的 Ubuntu 系统上（最快）

```bash
sudo tar xzf crux-overlay.tar.gz -C /
# 内核模块（按实际内核版本）
sudo mkdir -p /usr/lib/modules/$(uname -r)/extra
sudo cp modules/*.ko /usr/lib/modules/$(uname -r)/extra/
# 启用服务
for u in rmtfs tqftpserv pd-mapper hexagonrpcd-sdsp crux-ssc-registry iris-vpu \
         npu-svc crux-fastrpc-guard crux-touch-watchdog usb-gadget-acm usb-align qsee-supplicant \
         modem-mnt qcom-subsys-start crux-audio-route crux-time-sync crux-swap crux-ufs-stable \
         ufs-nopm crux-charger-init crux-crashsave crux-markshutdown crux-kmsg-tap dmesg-snap power-snap; do
  sudo systemctl enable --now $u.service
done
for t in crux-time-sync.timer qcom-subsys-start.timer; do
  sudo systemctl enable --now $t
done
```

### B. 从零构建最小 rootfs

```bash
sudo ./build.sh /mnt/target          # 默认 SUITE=resolute（Ubuntu 26.04）、ARCH=arm64
```

再把**内核模块装进目标 rootfs**（在设备内核源码树里执行）：

```bash
make O=build73 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install INSTALL_MOD_PATH=/mnt/target
```

### C. 装到设备

1. 把 rootfs 写到设备的分区（`linux-root*`，实测在 `/dev/sda36`/`sda37`），`/etc/fstab` 写 `root=UUID=<该分区UUID>`
2. GRUB 条目（ESP `EFI/crux/grub.cfg`）里给出对应的 `root=UUID=…`，并在菜单项里指定内核 `Image73`、initramfs 与 dtb
3. 设备访问一律用 **`crux.local`（mDNS）**，不要写死 IP

---

## 3.x 默认凭据（root 通用密码）

| 项 | 值 |
|---|---|
| 用户 | `root` |
| **通用密码** | **`root`** |
| SSH | 允许 root 用密码或 key 登录（`PermitRootLogin yes` / `PasswordAuthentication yes`） |

构建时可覆盖：`sudo ROOT_PASS=你的密码 ./build.sh /mnt/target`

> ⚠️ 出厂通用密码只为第一次进系统方便；**登录后第一件事就改掉**：`passwd root`

## 4. 已验证状态（2026-10-20 09:30 设备实测）

显示（DSI ea8076，`card0-DSI-1=connected`）、GPU、触摸（`fts`）、按键、UFS、`/vendor`+`/mnt/sys` 只读读取、
WiFi（`ath10k_snoc`，`wlan0` 静态 `192.168.1.240`）、四颗 remoteproc（slpi/modem/cdsp/adsp）全 running、
rmtfs/tqftpserv/ModemManager/modem-mnt 常驻、**NPU（`/dev/msm_npu` + `npu-svc` 运行中，InceptionV3 109 层 / 10.31 ms / 92.5%）**、
视频编解码（`/dev/video0/1`）、26 个 thermal zone、
**音频（Speaker + Earpiece 双设备可切、已实听出声，`hw_params = S16_LE/2ch/48000`）**均已就位。

> 基带部分本仓库只保证**内置四个子系统（mpss/adsp/cdsp/slpi）能起来**这条基础链，
> **不含外挂 X50（sdx50m）那一套**（`x50-*` 单元、`x50-mhi.conf`、`ipa_mhi_proxy.conf` 均未收录）。

---

## 5. 注意

- `npu-boot.service` 在设备原版里指向 `/root/npu_test/npu_boot24.ko`；**本仓库版已改为 `/usr/lib/modules/$(uname -r)/extra/npu_boot24.ko`**，不再依赖 `/root`
- `npu-svc` 默认只开 unix socket；需要局域网调用时设 `NPU_SVC_TCP=1`（TCP 5300）
- 服务之间有顺序依赖：`qrtr-ns` → `pd-mapper`/`tqftpserv` → `rmtfs`/`hexagonrpcd`
### 交换空间：哪部分是默认开的，哪部分要手动开

| 组成 | 落点 | 默认 | 打开方式 |
|---|---|---|---|
| zram 4 GiB（zstd，优先级 100） | 内存压缩，**不依赖任何分区** | ✅ 开 | 无需操作 |
| 8 GiB swapfile（优先级 10） | `/mnt/lroot`（`PARTLABEL=linux-root`，实测 `sda36` 64G） | ⛔ **关** | `/etc/crux-swap.conf` 里 `LROOT_SWAP=1`，同时 fstab 去掉 `/mnt/lroot` 那行的注释，然后 `systemctl restart crux-swap` |

**为什么默认关**：`sda36` 是可选的第二块盘，可能被删除并入根分区（根分区 24G 那个是 `sda37`）。
如果开机默认就去挂它，等于把启动路径绑在一块随时可能不存在的盘上。所以脚本和 unit 都改成
“只有 `LROOT_SWAP=1` 才碰 `/mnt/lroot`”，unit 里也不再有 `Wants=mnt-lroot.mount` 与挂载用的
`ExecStartPre`。默认路径下 `crux-swap` 只建 zram，`/mnt/lroot` 不存在也完全不影响开机。
- 基带只保底“四个子系统能起来”：`qcom-subsys-start` 的依赖里已去掉 X50 的 `x50-rfs-persist.service`
- 本包只是**适配层 + 基础系统**；桌面（KDE）、Docker 等按需自行安装
# crux 最小 rootfs（设备适配层）

> **Xiaomi Mi 9 Pro 5G（crux / SM8150）** 主线 Linux 用的**最小 rootfs 包**：
> 一份 Ubuntu 基础系统 + 针对该设备适配过的**全部用户态文件、systemd 服务和内核模块**。
>
> 导出时间：**2026-10-11**（取自设备当前实际运行的 rootfs：Ubuntu 26.04.1，内核 7.3.0-rc5）

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
         npu-svc crux-fastrpc-guard crux-touch-watchdog usb-gadget-acm usb-align qsee-supplicant; do
  sudo systemctl enable --now $u.service
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

## 4. 已验证状态（2026-10-11 08:30 设备实测）

显示（DSI ea8076，`card0-DSI-1=connected`）、GPU、触摸（`fts`）、按键、UFS、`/vendor`+`/mnt/sys` 只读读取、
WiFi（`ath10k_snoc`，`wlan0` 关联成功）、四颗 remoteproc（slpi/modem/cdsp/adsp）全 running、
rmtfs/tqftpserv/ModemManager 常驻、**NPU（`/dev/msm_npu` + `npu-svc` 运行中，实测 InceptionV3 109 层 / 10.31 ms / 92.5%）**、
视频编解码（`/dev/video0/1`）、26 个 thermal zone 均已就位。

---

## 5. 注意

- `npu-boot.service` 在设备原版里指向 `/root/npu_test/npu_boot24.ko`；**本仓库版已改为 `/usr/lib/modules/$(uname -r)/extra/npu_boot24.ko`**，不再依赖 `/root`
- `npu-svc` 默认只开 unix socket；需要局域网调用时设 `NPU_SVC_TCP=1`（TCP 5300）
- 服务之间有顺序依赖：`qrtr-ns` → `pd-mapper`/`tqftpserv` → `rmtfs`/`hexagonrpcd`
- 本包只是**适配层 + 基础系统**；桌面（KDE）、Docker 等按需自行安装
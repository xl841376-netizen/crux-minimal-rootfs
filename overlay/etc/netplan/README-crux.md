# 网络配置由 NetworkManager 负责（renderer: NetworkManager）

在役机器上的 WiFi 连接由 netplan 生成到 `/etc/netplan/90-NM-*.yaml`，其中含 WiFi 密码，
**不放进本仓库**。要预置自己的网络（含密码），用 `mkimage.sh --private <目录>`，
把在役机器的 `/etc/netplan/` 与 `/root/.ssh/authorized_keys` 放进去即可：

```bash
mkdir -p mypriv/etc
cp -a /etc/netplan mypriv/etc/
mkdir -p mypriv/root/.ssh
cp -a /root/.ssh/authorized_keys mypriv/root/.ssh/
sudo ./mkimage.sh out --fw-dir fw --selections deps/lists/sda37.list --private mypriv
```

没有预置时，开机用 `nmtui` 连 WiFi，或用 USB ECM（usb0 固定 192.168.2.2/24）直连。

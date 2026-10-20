#!/bin/bash
# crux: 依赖就绪保障器（不是"关掉谁"，而是"缺依赖就等、就重试"）
#
# 审计结论（见 /var/log/qcom-subsys-start.log 每次刷新）：
#   mpss : 依赖 rmtfs（EFS: modemst1/2+fsc+fsg）  -> 等 + 重试
#   cdsp : 依赖 rootfs 里的 cdsp.mbn              -> 若 fail 就重试
#   slpi : 依赖 rootfs 里的 slpi.mbn              -> 若 fail 就重试
#   adsp : 固件内嵌在内核 EXTRA_FIRMWARE           -> 不依赖 FS
set -u
LOG=/var/log/qcom-subsys-start.log
exec >> $LOG 2>&1
echo "=== $(date) qcom-subsys-start begin ==="

# ---------- 1) 等分区符号链接 ----------
for i in $(seq 1 60); do
  ok=1
  for p in modemst1 modemst2 fsc fsg; do
    [ -e /dev/disk/by-partlabel/$p ] || ok=0
  done
  [ $ok -eq 1 ] && break
  sleep 0.5
done
echo "partitions: modemst1=$([ -e /dev/disk/by-partlabel/modemst1 ] && echo ok || echo MISSING)"

# ---------- 2) 等服务 active ----------
wait_unit() {
  local u=$1 n=${2:-60}
  for i in $(seq 1 $n); do
    systemctl is-active --quiet "$u" && { echo "unit $u: active"; return 0; }
    sleep 0.5
  done
  echo "unit $u: NOT active (continuing)"
  return 1
}
wait_unit rmtfs.service 80
wait_unit pd-mapper.service 40

# ---------- 3) rproc 工具 ----------
rproc_dir() {
  local want=$1 d
  for d in /sys/class/remoteproc/remoteproc*; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/name" 2>/dev/null)" = "$want" ] && { echo "$d"; return 0; }
  done
  return 1
}
state_of() { local d; d=$(rproc_dir "$1") && cat "$d/state" 2>/dev/null || echo "no-node"; }

# 启动一个子系统；失败会再等再试，不放弃（这是"等待"而不是"关掉"）
ensure_subsys() {
  local want=$1 label=$2 rounds=${3:-6} d
  local r
  for r in $(seq 1 $rounds); do
    d=$(rproc_dir "$want") || { echo "$label: node $want missing (round $r)"; sleep 5; continue; }
    [ "$(cat "$d/state" 2>/dev/null)" = "running" ] && {
      echo "$label: RUNNING (round $r)"; return 0; }
    echo "$label: state=$(cat "$d/state" 2>/dev/null) -> echo start (round $r)"
    echo start > "$d/state" 2>/dev/null
    local i
    for i in $(seq 1 20); do
      [ "$(cat "$d/state" 2>/dev/null)" = "running" ] && {
        echo "$label: RUNNING after start (round $r, $((i*500))ms)"; return 0; }
      sleep 0.5
    done
    echo "$label: still $(cat "$d/state" 2>/dev/null) — 等 5s 再试"
    sleep 5
  done
  echo "$label: 已重试 $rounds 轮仍未起来，保留现场（不放弃、不卸载）"
  dmesg | grep -iE "remoteproc|q6v5|$want" | tail -10
  return 1
}

# ---------- 4) 逐个保障（顺序：mpss 先，cdsp/slpi 固件在 rootfs 上） ----------
ensure_subsys modem  mpss  8
ensure_subsys cdsp  cdsp  2
ensure_subsys slpi  slpi  2

# ---------- 5) 快照：所有 rproc 最终状态 + 缺固件证据 ----------
echo "--- rproc snapshot ---"
for d in /sys/class/remoteproc/remoteproc*; do
  [ -d "$d" ] && echo "$(basename $d) $(cat $d/name) state=$(cat $d/state)"
done
echo "--- 固件缺失证据（本次 boot） ---"
dmesg | grep -iE "Direct firmware load|request_firmware failed|failed with error -2" | tail -10

echo "=== $(date) qcom-subsys-start done ==="
exit 0
#!/bin/bash
# crux: 开机自动校时（后台重试，不阻塞启动）
#
# 时间源优先级：
#   1) 宿主侧本地时间源  http://192.168.2.1:18080/  （USB ECM，永远可用、不依赖外网）
#   2) 局域网网关 NTP    192.168.1.1
#   3) 公网 NTP          ntp.aliyun.com / cn.pool.ntp.org / time1.cloud.tencent.com
#   4) 公网 HTTP Date    baidu / taobao 兜底
# 成功后用 busybox hwclock -w 回写 RTC（设备无 util-linux hwclock）
set -u
LOG=/var/log/crux-time-sync.log
exec >> $LOG 2>&1
echo "=== $(date '+%F %T %Z') crux-time-sync begin (epoch=$(date +%s)) ==="

PLAUSIBLE_EPOCH=1700000000
LOCAL_HTTP="http://192.168.2.1:18080/"
NTP_SERVERS="192.168.1.1 ntp.aliyun.com cn.pool.ntp.org time1.cloud.tencent.com"
HTTP_URLS="https://www.baidu.com http://www.baidu.com https://www.taobao.com"

have() { command -v "$1" >/dev/null 2>&1; }

[ "$(date +%s)" -ge "$PLAUSIBLE_EPOCH" ] \
  && echo "当前时间: $(date '+%F %T %Z')" \
  || echo "当前时间不可信: $(date '+%F %T') -> 必须校准"

net_up() {
  ping -c1 -W2 192.168.2.1 >/dev/null 2>&1 && return 0
  ping -c1 -W2 192.168.1.1 >/dev/null 2>&1 && return 0
  ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && return 0
  getent hosts ntp.aliyun.com >/dev/null 2>&1
}

set_from_http() {
  local d
  d=$(timeout 12 curl -s -k -I "$1" 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2; exit}')
  [ -z "$d" ] && return 1
  date -s "$d" >/dev/null 2>&1 || return 1
  echo "ok: HTTP Date <- $1 ($d)"
  return 0
}
try_local_http() { set_from_http "$LOCAL_HTTP"; }
try_internet_http() {
  local u
  for u in $HTTP_URLS; do set_from_http "$u" && return 0; done
  return 1
}
try_ntp() {
  local s
  if have chronyd; then
    for s in $NTP_SERVERS; do
      timeout 12 chronyd -q -t 8 "server $s iburst" >/dev/null 2>&1 && { echo "ok: chronyd $s"; return 0; }
    done
  fi
  if have sntp; then
    for s in $NTP_SERVERS; do
      timeout 12 sntp -sS -t 8 "$s" >/dev/null 2>&1 && { echo "ok: sntp $s"; return 0; }
    done
  fi
  if have ntpdate; then
    for s in $NTP_SERVERS; do
      timeout 12 ntpdate -u -t 8 "$s" >/dev/null 2>&1 && { echo "ok: ntpdate $s"; return 0; }
    done
  fi
  if busybox --list 2>/dev/null | grep -qx ntpd; then
    for s in $NTP_SERVERS; do
      timeout 14 busybox ntpd -q -n -p "$s" >/dev/null 2>&1 && { echo "ok: busybox ntpd $s"; return 0; }
    done
  fi
  return 1
}

write_rtc() {
  if [ -e /dev/rtc0 ]; then
    if have hwclock; then hwclock -w 2>/dev/null && echo "RTC 已回写(hwclock)" && return 0; fi
    TZ=UTC busybox hwclock -w 2>/dev/null && echo "RTC 已回写(busybox)" && return 0
    echo "RTC 回写失败(忽略)"
  else
    echo "无 /dev/rtc0，跳过 RTC 回写"
  fi
}

n=0
while [ $n -lt 40 ]; do
  n=$((n+1))
  if net_up; then
    echo "[$n] link up, trying sync..."
    if try_local_http || try_ntp || try_internet_http; then
      echo "校时成功: $(date '+%F %T %Z')"
      write_rtc
      echo "=== $(date '+%F %T') done ==="
      exit 0
    fi
    echo "[$n] 本轮全部失败，15s 后重试"
    sleep 15
  else
    echo "[$n] link down，等 10s"
    sleep 10
  fi
done

echo "校时放弃，系统时间: $(date '+%F %T %Z')"
echo "=== $(date '+%F %T') done(failed) ==="
exit 0
#!/usr/bin/env python3
# x50-uim-activate-safe.py  v2
# 策略（对齐上游/原厂）：有限重试 + 明确终态 + 事件驱动
#  - 一次启动流程里，noatr/absent 连读两次确认即写终态，之后本 boot 内不再碰 QMI
#  - --monitor 模式：被动监听 slot status 事件，只有卡状态变化才清终态并重试一次
import subprocess, time, re, sys, os

LOG = "/var/log/x50-uim-activate.log"
STATE = "/run/x50-card-error"
DEV = os.environ.get("UIMDEV", "qrtr://0")
AID = os.environ.get("UIMAID", "A0000000871002FF86FFFF89FFFFFFFF")
CONFIRM_GAP = int(os.environ.get("CONFIRM_GAP", "10"))

def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass

def qmi(args, t=20):
    cmd = ["timeout", str(t), "qmicli", "-d", DEV] + args
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=t + 5)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return 99, "EXC:%s" % e

TARGET_SLOT = os.environ.get("TARGET_SLOT", "2")

def parse_slots(out):
    """按 Slot [n]: 分块解析，返回 {slot: (card_state, app_state)}"""
    res = {}
    parts = re.split(r"Slot \[(\d+)\]:", out)
    # parts = [head, n1, body1, n2, body2, ...]
    for i in range(1, len(parts) - 1, 2):
        idx = parts[i]
        body = parts[i + 1]
        m = re.search(r"Card state:\s*'([^']*)'", body)
        cs = m.group(1) if m else ""
        m = re.search(r"Application state:\s*'([^']*)'", body)
        ap = m.group(1) if m else ""
        res[idx] = (cs, ap)
    return res

def probe():
    rc, out = qmi(["--uim-get-card-status"])
    if rc == 99 or "EXC:" in out:
        return "noqmi", "no qmi answer"
    if re.search(r"[Nn]o card", out):
        return "absent", "no card reported"
    slots = parse_slots(out)
    if not slots:
        return "unknown", "no slot block parsed"
    cs, ap = slots.get(TARGET_SLOT, ("", ""))
    if not cs and not ap:
        # 目标槽没有块：若只有一个可用槽就退回它
        present = [(k, v) for k, v in slots.items() if "present" in v[0].lower()]
        if len(present) == 1:
            T = present[0][0]
            cs, ap = present[0][1]
            return _classify(cs, ap, "slot%s(fallback)" % T)
        return "absent", "target slot %s not reported" % TARGET_SLOT
    return _classify(cs, ap, "slot%s" % TARGET_SLOT)

def _classify(cs, ap, tag):
    d = "%s Card state=%s Application=%s" % (tag, cs, ap)
    if "no-atr-received" in cs:
        return "noatr", d
    if "absent" in cs.lower():
        return "absent", d
    if ap == "ready":
        return "ready", d
    if "detected" in ap or "not-initialized" in ap:
        return "need", d
    return "unknown", d

def set_state(kind, detail):
    try:
        with open(STATE, "w") as f:
            f.write("%s %s %s\n" % (kind, time.strftime("%Y-%m-%d %H:%M:%S"), detail))
    except Exception:
        pass
    log("terminal-state: %s (%s)" % (kind, detail))

def clear_state():
    try:
        os.unlink(STATE)
        log("terminal-state cleared")
    except FileNotFoundError:
        pass

def activate():
    rc, out = qmi(["--uim-change-provisioning-session=session-type=primary-gw-provisioning,activate=yes,slot=2,aid=%s" % AID], t=30)
    tail = (out.strip().splitlines() or [""])[-1]
    log("activate rc=%d: %s" % (rc, tail))
    return rc == 0

def wait_dev(timeout=180):
    """等 QMI 设备节点出现，纯文件检查，不产生任何 QMI 流量。"""
    node = os.environ.get("QMIDEV", "/dev/wwan0qmi0")
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(node):
            log("wait_dev: %s appeared after %ds" % (node, int(time.time() - t0)))
            time.sleep(3)
            return True
        time.sleep(5)
    log("wait_dev: %s never appeared in %ds" % (node, timeout))
    return False

def oneshot():
    if os.environ.get("WAIT_DEV") == "1":
        wait_dev(int(os.environ.get("WAIT_DEV_TIMEOUT", "180")))
    if os.path.exists(STATE):
        try:
            cur = open(STATE).read().strip()
        except Exception:
            cur = "?"
        log("skip: terminal state present (%s)" % cur)
        return 0

    kind, detail = probe()
    log("probe#1 state=%s (%s)" % (kind, detail))

    if kind == "ready":
        log("ok: card ready, nothing to do")
        return 0

    if kind in ("noatr", "absent"):
        time.sleep(CONFIRM_GAP)
        kind2, detail2 = probe()
        log("probe#2 state=%s (%s)" % (kind2, detail2))
        if kind2 == kind:
            set_state(kind, detail2)
            log("ABORT: %s confirmed twice -> stop touching QMI this boot" % kind)
            return 0
        kind = kind2

    if kind == "need":
        if not activate():
            set_state("activate-failed", "change-provisioning-session rc!=0")
            return 0
        time.sleep(2)
        kind3, detail3 = probe()
        log("post-check state=%s (%s)" % (kind3, detail3))
        if kind3 == "ready":
            log("ok: activation succeeded")
        else:
            set_state(kind3, detail3)
        return 0

    log("give-up: state=%s, no retry in this pass" % kind)
    return 0

def monitor():
    """被动事件监听：只在卡状态变化/插拔时清终态并试一次。"""
    log("monitor: start slot-status watch")
    while True:
        p = subprocess.Popen(["timeout", "180", "qmicli", "-d", DEV, "--uim-monitor-slot-status"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        changed = False
        for line in p.stdout:
            line = line.rstrip()
            if not line:
                continue
            low = line.lower()
            if "card state" in low or "physical slot status" in low:
                log("monitor: %s" % line)
                if "no-atr-received" in low or "absent" in low:
                    changed = False
                elif "present" in low:
                    changed = True
        p.wait()
        if changed:
            log("monitor: card event -> clear terminal state, retry once")
            clear_state()
            oneshot()
        time.sleep(30)

if __name__ == "__main__":
    if "--monitor" in sys.argv:
        sys.exit(monitor())
    sys.exit(oneshot())
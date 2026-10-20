#!/usr/bin/env python3
"""X50 UIM: activate provisioning session once modem UIM is up."""
import subprocess, time, sys, re, datetime

LOG = "/run/x50-uim-activate.log"
AID_FB = "A0000000871002FF86FFFF89FFFFFFFF"


def log(msg):
    with open(LOG, "a") as f:
        f.write("%s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), msg))


def card_status():
    try:
        r = subprocess.run(["timeout", "20", "qmicli", "-d", "qrtr://0", "--uim-get-card-status"],
                           capture_output=True, text=True, timeout=30)
        return r.stdout + r.stderr
    except Exception:
        return ""


log("start")
for i in range(1, 181):
    out = card_status()
    slot = None
    cur = None
    lines = out.splitlines()
    for line in lines:
        m = re.match(r"\s*Slot \[(\d+)\]:", line)
        if m:
            cur = m.group(1)
        if "Card state: 'present'" in line and cur:
            slot = cur
            break
    if not slot:
        if i % 6 == 0:
            log("wait#%d no-slot" % i)
        time.sleep(5)
        continue

    aid = None
    for j, line in enumerate(lines):
        if "Application ID" in line:
            for k in range(j + 1, min(j + 3, len(lines))):
                v = re.sub(r"[^0-9A-Fa-f]", "", lines[k])
                if len(v) >= 32:
                    aid = v[:32].upper()
                    break
            break
    if not aid:
        aid = AID_FB

    log("try#%d slot=%s aid=%s" % (i, slot, aid))
    try:
        r = subprocess.run(["timeout", "30", "qmicli", "-d", "qrtr://0",
                            "--uim-change-provisioning-session=session-type=primary-gw-provisioning,activate=yes,slot=%s,aid=%s" % (slot, aid)],
                           capture_output=True, text=True, timeout=40)
        res = (r.stdout + r.stderr).strip()
    except Exception as e:
        res = "exception: %s" % e
    log("result: " + res.replace("\n", " | "))
    if "uccess" in res:
        log("OK")
        sys.exit(0)
    time.sleep(5)

log("give-up")
sys.exit(1)

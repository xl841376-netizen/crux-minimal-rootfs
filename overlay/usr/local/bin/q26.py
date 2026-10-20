#!/usr/bin/env python3
# UIM REGISTER_EVENTS (0x0026) + 监听 indication
import socket, struct, sys, time
AF_QIPCRTR = 42
QRTR_NODE_BCAST = 0xffffffff
QRTR_PORT_CTRL = 0xfffffffe
NEW_LOOKUP = 10
NEW_SERVER = 4

def lookup(s, service):
    s.sendto(struct.pack("<I", NEW_LOOKUP), (QRTR_NODE_BCAST, QRTR_PORT_CTRL))
    s.settimeout(1.0)
    out = []
    try:
        while True:
            d, _ = s.recvfrom(4096)
            if len(d) < 20:
                break
            cmd, svc, inst, node, port = struct.unpack("<IIIII", d[:20])
            if cmd != NEW_SERVER:
                continue
            if svc == 0 and inst == 0 and node == 0 and port == 0:
                break
            if svc == service:
                out.append((node, port))
    except socket.timeout:
        pass
    return out

def tlv(t, v=b""):
    return struct.pack("<BH", t, len(v)) + v

s = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
srv = lookup(s, 11)
print("UIM servers:", srv, flush=True)
if not srv:
    sys.exit(1)
node, port = srv[0]
mode = sys.argv[1] if len(sys.argv) > 1 else "all"
if mode == "slot":
    body = tlv(0x10)
elif mode == "card":
    body = tlv(0x11)
else:
    body = tlv(0x10) + tlv(0x11) + tlv(0x12)
txn = int(time.time()) & 0xffff
hdr = struct.pack("<BHHH", 0, txn, 0x0026, len(body))
s.sendto(hdr + body, (node, port))
s.settimeout(20)
try:
    d, _ = s.recvfrom(4096)
    print("register resp:", d.hex(), flush=True)
except socket.timeout:
    print("register timeout", flush=True)

secs = int(sys.argv[2]) if len(sys.argv) > 2 else 90
print("listening %ds ..." % secs, flush=True)
s.settimeout(1.0)
end = time.time() + secs
n = 0
while time.time() < end:
    try:
        d, a = s.recvfrom(8192)
    except socket.timeout:
        continue
    n += 1
    t = d[0]
    mid = struct.unpack("<H", d[3:5])[0] if len(d) >= 7 else -1
    print("[%.1f] ind type=%d msg=0x%04x len=%d %s" % (time.time(), t, mid, len(d), d.hex()), flush=True)
print("total indications:", n, flush=True)

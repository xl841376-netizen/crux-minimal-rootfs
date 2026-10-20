#!/usr/bin/env python3
# qraw.py <msgid_hex> [body_hex] [service]  -> dump raw QMI response TLVs
import socket, struct, sys, time
AF_QIPCRTR = 42
QRTR_NODE_BCAST = 0xffffffff
QRTR_PORT_CTRL = 0xfffffffe

def lookup(s, service):
    s.sendto(struct.pack("<I", 10), (QRTR_NODE_BCAST, QRTR_PORT_CTRL))
    s.settimeout(1.0)
    out = []
    try:
        while True:
            d, _ = s.recvfrom(4096)
            if len(d) < 20:
                break
            cmd, svc, inst, node, port = struct.unpack("<IIIII", d[:20])
            if cmd != 4:
                continue
            if svc == 0 and inst == 0 and node == 0 and port == 0:
                break
            if svc == service:
                out.append((node, port))
    except socket.timeout:
        pass
    return out

mid = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0x002F
body = bytes.fromhex(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else b""
svc = int(sys.argv[3]) if len(sys.argv) > 3 else 11
s = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
srv = lookup(s, svc)
print("servers:", srv, flush=True)
if not srv:
    sys.exit(1)
node, port = srv[0]
txn = int(time.time()) & 0xffff
s.sendto(struct.pack("<BHHH", 0, txn, mid, len(body)) + body, (node, port))
s.settimeout(30)
try:
    d, _ = s.recvfrom(16384)
except socket.timeout:
    print("timeout"); sys.exit(2)
print("raw:", d.hex(), flush=True)
t, tx, m, ln = struct.unpack("<BHHH", d[:7])
p = 7
while p + 3 <= len(d):
    tt, tl = struct.unpack("<BH", d[p:p+3]); p += 3
    v = d[p:p+tl]; p += tl
    print("  TLV 0x%02x len=%d %s" % (tt, tl, v.hex()))

#!/usr/bin/env python3
import socket, struct, sys, time, select
AF = 42
BC = 0xffffffff
CTL = 0xfffffffe
def lookup(s, svc, to=3.0):
    s.sendto(struct.pack("<I", 10), (BC, CTL))
    out = []
    end = time.time() + to
    while time.time() < end:
        r, _, _ = select.select([s], [], [], max(0.05, end - time.time()))
        if not r:
            break
        d, _ = s.recvfrom(4096)
        if len(d) < 20:
            break
        c, a, b, node, port = struct.unpack("<IIIII", d[:20])
        if c != 4:
            continue
        if a == 0 and b == 0 and node == 0 and port == 0:
            break
        if a == svc:
            out.append((node, port))
    return out
msg = int(sys.argv[1], 16)
body = bytes.fromhex(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else b""
svc = int(sys.argv[3]) if len(sys.argv) > 3 else 11
to = float(sys.argv[4]) if len(sys.argv) > 4 else 8.0
s = socket.socket(AF, socket.SOCK_DGRAM, 0)
srv = lookup(s, svc)
print("svc%d:" % svc, srv, flush=True)
if not srv:
    sys.exit(1)
node, port = srv[0]
s.sendto(struct.pack("<BHHH", 0, int(time.time()) & 0xffff, msg, len(body)) + body, (node, port))
r, _, _ = select.select([s], [], [], to)
if not r:
    print("NO REPLY in %.0fs" % to, flush=True)
    sys.exit(2)
d, _ = s.recvfrom(65536)
print("raw:", d.hex(), flush=True)
p = 7
while p + 3 <= len(d):
    t, l = struct.unpack("<BH", d[p:p+3]); p += 3
    v = d[p:p+l]; p += l
    note = ""
    if t == 0x02 and l >= 4:
        note = " result=0x%04x error=0x%04x" % (struct.unpack("<H", v[0:2])[0], struct.unpack("<H", v[2:4])[0])
    print("  TLV 0x%02x len=%d %s%s" % (t, l, v.hex(), note))

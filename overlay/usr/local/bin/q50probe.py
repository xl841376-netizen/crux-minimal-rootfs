#!/usr/bin/env python3
import socket, struct, sys, time

AF = 42
def mk():
    return socket.socket(AF, socket.SOCK_DGRAM)

def lookup(s, svc):
    s.settimeout(1.0)
    s.sendto(struct.pack('<I', 10), (0xffffffff, 0xfffffffe))
    out = []
    deadline = time.time() + 2
    while time.time() < deadline:
        try:
            d, _ = s.recvfrom(4096)
        except socket.timeout:
            break
        if len(d) < 20:
            continue
        c = struct.unpack('<IIIII', d[:20])
        if c[0] == 4 and c[1] == svc:
            out.append((c[3], c[4]))
    return out

def hdr(t, txn, mid, n):
    return struct.pack('<BHHH', t, txn, mid, n)

def res_of(d):
    if len(d) < 7:
        return None
    p = 7
    r = None
    while p + 3 <= len(d):
        tt, tl = struct.unpack('<BH', d[p:p+3]); p += 3
        v = d[p:p+tl]; p += tl
        if tt == 0x02 and tl >= 4:
            r = struct.unpack('<HH', v[:4])
    return r

def main():
    s = mk()
    srv = lookup(s, 50)
    print('svc50:', srv, flush=True)
    if not srv:
        print('no service50', flush=True); return 1
    node, port = srv[0]
    for ev in [0, 1, 2, 3, 4, 5, 6]:
        body = bytearray(0x60)
        body[0] = ev
        body[1] = 0
        txn = int(time.time() * 997) & 0xffff
        s.sendto(hdr(0, txn, 0x21, len(body)) + bytes(body), (node, port))
        s.settimeout(2.0)
        try:
            d, _ = s.recvfrom(8192)
            print('ev=%d resp msg=0x%04x result=%s' % (ev, struct.unpack('<BHHH', d[:7])[2], res_of(d)), flush=True)
        except socket.timeout:
            print('ev=%d timeout' % ev, flush=True)
    return 0

sys.exit(main())
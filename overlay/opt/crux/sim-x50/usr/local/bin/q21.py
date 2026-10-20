#!/usr/bin/env python3
# 向 UIMRMT(service 50) 发 0x21 EventReq，event code 0..6 逐个试
import socket, struct, sys, time

AF_QIPCRTR = 42
NEW_LOOKUP = 10
NEW_SERVER = 4
SVC = 50

def lookup(s, service):
    s.sendto(struct.pack('<I', NEW_LOOKUP), (0xffffffff, 0xfffffffe))
    s.settimeout(1.0)
    out = []
    try:
        while True:
            d, _ = s.recvfrom(4096)
            if len(d) < 20:
                break
            cmd, svc, inst, node, port = struct.unpack('<IIIII', d[:20])
            if cmd != NEW_SERVER:
                continue
            if svc == 0 and inst == 0 and node == 0 and port == 0:
                break
            if svc == service:
                out.append((node, port))
    except socket.timeout:
        pass
    return out

def main():
    codes = [int(x) for x in sys.argv[1:]] or list(range(7))
    s = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    srv = lookup(s, SVC)
    print('servers:', srv, flush=True)
    if not srv:
        return 1
    node, port = srv[0]
    for c in codes:
        body = bytearray(0x60)
        body[0] = c
        body[1] = 0
        txn = (int(time.time() * 1000) + c) & 0xffff
        pkt = struct.pack('<BHHH', 0, txn, 0x0021, len(body)) + bytes(body)
        s.sendto(pkt, (node, port))
        s.settimeout(3)
        try:
            d, _ = s.recvfrom(8192)
            t, t2, mid, ln = struct.unpack('<BHHH', d[:7])
            p = 7
            res = None
            while p + 3 <= len(d):
                tt, tl = struct.unpack('<BH', d[p:p+3]); p += 3
                val = d[p:p+tl]; p += tl
                if tt == 0x02 and tl >= 4:
                    res = struct.unpack('<HH', val[:4])
            print('event=%d -> msg=0x%04x result=%s raw=%s' % (c, mid, res, d[:24].hex()), flush=True)
        except socket.timeout:
            print('event=%d -> timeout' % c, flush=True)
        time.sleep(1)
    return 0

sys.exit(main())
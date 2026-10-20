#!/usr/bin/env python3
# crux: UIM Remote (QMI service 50) 被动监听器（7字节头）
import socket, struct, sys, time

AF_QIPCRTR = 42
QRTR_NODE_BCAST = 0xffffffff
QRTR_PORT_CTRL = 0xfffffffe
NEW_LOOKUP = 10
NEW_SERVER = 4
SVC_UIMRMT = 50

def lookup(s, service):
    s.sendto(struct.pack('<I', NEW_LOOKUP), (QRTR_NODE_BCAST, QRTR_PORT_CTRL))
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

def parse(d):
    if len(d) < 7:
        return None
    t, txn, mid, ln = struct.unpack('<BHHH', d[:7])
    tlvs = []
    p = 7
    while p + 3 <= len(d):
        tt, tl = struct.unpack('<BH', d[p:p+3]); p += 3
        tlvs.append((tt, d[p:p+tl])); p += tl
    return t, txn, mid, tlvs

def main():
    s = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    srv = lookup(s, SVC_UIMRMT)
    print('UIMRMT servers:', srv, flush=True)
    if not srv:
        return 1
    node, port = srv[0]
    s.sendto(struct.pack('<BHHH', 0, 0x1234, 0x001E, 0), (node, port))
    print('registered -> node %d port %d' % (node, port), flush=True)
    s.settimeout(None)
    while True:
        d, _ = s.recvfrom(8192)
        r = parse(d)
        if not r:
            print('raw', d.hex(), flush=True); continue
        t, txn, mid, tlvs = r
        print('[%s] type=%d txn=0x%04x msg=0x%04x total=%d' % (time.strftime('%H:%M:%S'), t, txn, mid, len(d)), flush=True)
        for tt, val in tlvs:
            print('    TLV 0x%02x len=%d %s' % (tt, len(val), val[:80].hex()), flush=True)
    return 0

sys.exit(main())
#!/usr/bin/env python3
# 直接走 QRTR 发 QMI 0x0038 UIM_CHANGE_PROVISIONING_SESSION（7字节标准头）
import socket, struct, sys, time

AF_QIPCRTR = 42
QRTR_NODE_BCAST = 0xffffffff
QRTR_PORT_CTRL = 0xfffffffe
NEW_LOOKUP = 10
NEW_SERVER = 4

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

def tlv(t, v):
    return struct.pack('<BH', t, len(v)) + v

def main():
    stype = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    slot = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    act = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    aid = bytes.fromhex(sys.argv[4]) if len(sys.argv) > 4 else b''
    s = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    srv = lookup(s, 11)
    print('UIM servers:', srv)
    if not srv:
        return 1
    node, port = srv[0]
    body = tlv(0x01, struct.pack('<BB', stype, act))
    body += tlv(0x10, struct.pack('<BB', slot, len(aid)) + aid)
    txn = int(time.time()) & 0xffff
    hdr = struct.pack('<BHHH', 0, txn, 0x0038, len(body))
    s.sendto(hdr + body, (node, port))
    s.settimeout(30)
    try:
        d, _ = s.recvfrom(4096)
    except socket.timeout:
        print('timeout'); return 2
    print('resp raw:', d.hex())
    t, txn2, mid, ln = struct.unpack('<BHHH', d[:7])
    p = 7
    res = None
    while p + 3 <= len(d):
        tt, tl = struct.unpack('<BH', d[p:p+3]); p += 3
        val = d[p:p+tl]; p += tl
        if tt == 0x02 and tl >= 4:
            res = struct.unpack('<HH', val[:4])
    print('type=%d txn=0x%04x msg=0x%04x result=%s' % (t, txn2, mid, res))
    return 0

sys.exit(main())
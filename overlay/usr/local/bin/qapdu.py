#!/usr/bin/env python3
# 0x003B SEND_APDU: qapdu.py <slot> <channel> <apdu_hex>
import socket, struct, sys, time
AF=42; BC=0xffffffff; CTL=0xfffffffe
def lookup(s,svc):
    s.sendto(struct.pack("<I",10),(BC,CTL)); s.settimeout(1.0); out=[]
    try:
        while True:
            d,_=s.recvfrom(4096)
            if len(d)<20: break
            c,a,b,node,port=struct.unpack("<IIIII",d[:20])
            if c!=4: continue
            if a==0 and b==0 and node==0 and port==0: break
            if a==svc: out.append((node,port))
    except socket.timeout: pass
    return out
def tlv(t,v=b""): return struct.pack("<BH",t,len(v))+v
slot=int(sys.argv[1]); ch=int(sys.argv[2]); apdu=bytes.fromhex(sys.argv[3])
s=socket.socket(AF,socket.SOCK_DGRAM,0)
srv=lookup(s,11)
if not srv: print("no uim"); sys.exit(1)
node,port=srv[0]
body=tlv(0x01,bytes([slot]))+tlv(0x02,struct.pack("<H",len(apdu))+apdu)+tlv(0x10,bytes([ch]))
s.sendto(struct.pack("<BHHH",0,int(time.time())&0xffff,0x003B,len(body))+body,(node,port))
s.settimeout(30)
try: d,_=s.recvfrom(16384)
except socket.timeout: print("timeout"); sys.exit(2)
print("raw:",d.hex())
p=7
while p+3<=len(d):
    t,l=struct.unpack("<BH",d[p:p+3]); p+=3; v=d[p:p+l]; p+=l
    extra=""
    if t==0x02 and l>=4: extra=" result=%d error=0x%x"%(struct.unpack(">H",v[0:2])[0],struct.unpack(">H",v[2:4])[0])
    if t==0x10: extra=" APDU_RESP(SW1SW2)=%s"%v[-2:].hex()
    print("  TLV 0x%02x len=%d %s%s"%(t,l,v.hex(),extra))

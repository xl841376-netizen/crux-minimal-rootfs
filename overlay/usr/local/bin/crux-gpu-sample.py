#!/usr/bin/env python3
# /usr/local/bin/crux-gpu-sample.py
# 把 GPU 数据写进 DRM 标准接口文件（供 GNOME Resources 等任何程序读）
import glob, re, time, os

DEV = "/run/crux-gpu-iface/card0/device"
HWM = DEV + "/hwmon/hwmon0"

def read(p):
    try:
        return open(p, errors='ignore').read()
    except Exception:
        return ''

def snap():
    """client_id -> (engine_ns, resident_kib)"""
    out = {}
    for f in glob.glob('/proc/[0-9]*/fdinfo/*'):
        c = read(f)
        if 'drm-engine-gpu' not in c:
            continue
        d = {}
        for line in c.splitlines():
            if line.startswith('drm-') and ':' in line:
                k, v = line.split(':', 1)
                d[k.strip()] = v.strip()
        def n(key):
            m = re.match(r'(\d+)', d.get(key, '0') or '0')
            return int(m.group(1)) if m else 0
        cid = d.get('drm-client-id')
        if cid:
            out[cid] = (n('drm-engine-gpu'), n('drm-resident-memory'))
    return out

def write(p, v):
    try:
        with open(p, 'w') as fh:
            fh.write(str(v) + "\n")
    except Exception:
        pass

# --- 采样两次算利用率 ---
a = snap(); t0 = time.time()
time.sleep(1.0)
b = snap(); t1 = time.time()
dt = (t1 - t0) * 1e9

d_eng = sum(max(0, b[k][0] - a[k][0]) for k in b if k in a)
busy = int(round(min(100.0, max(0.0, d_eng / dt * 100.0)))) if dt else 0

used_kib = sum(v[1] for v in b.values())
total_kib = int((read('/proc/meminfo').split('MemTotal:')[1]).split()[0])   # UMA：共享系统内存

# GPU 频率（devfreq）与温度（hwmon）
freq = 0
try:
    freq = int(read('/sys/class/devfreq/2c00000.gpu/cur_freq').strip() or 0)
except Exception:
    pass
temp = 0
for h in glob.glob('/sys/class/hwmon/hwmon*'):
    if read(h + '/name').strip() == 'gpu_top_thermal':
        try:
            temp = int(read(h + '/temp1_input').strip())
        except Exception:
            pass
        break

os.makedirs(HWM, exist_ok=True)

# DRM 标准接口三件套
write(DEV + "/gpu_busy_percent", busy)
write(DEV + "/mem_info_vram_used", used_kib * 1024)
write(DEV + "/mem_info_vram_total", total_kib * 1024)

# 附带一个"人看"的共享内存文件（= 常驻内存）
write(DEV + "/mem_info_shared_used", used_kib * 1024)

# hwmon（让 Resources 能读温度/频率）
write(HWM + "/name", "gpu_top_thermal")
write(HWM + "/temp1_input", temp)
write(HWM + "/freq1_input", freq)

if os.environ.get('CRUX_GPU_DEBUG'):
    print("busy=%d%%  resident=%.1f MB  freq=%d Hz  temp=%.1f C" % (
        busy, used_kib/1024, freq, temp/1000.0))
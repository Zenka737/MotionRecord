#!/usr/bin/env python3
"""Generates the built-in royalty-free sound pack (our own synthesis) into Resources/Sounds."""
import math, random, struct, wave, os
SR = 44100
out = os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds")
os.makedirs(out, exist_ok=True)
random.seed(7)

def write(name, samples, gain=0.85):
    peak = max(1e-9, max(abs(s) for s in samples))
    with wave.open(os.path.join(out, name + ".wav"), "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s / peak * gain)) * 32767)) for s in samples))

def env(n, a=0.003, d=0.2):
    return [min(1, i / max(1, a * SR)) * math.exp(-i / SR / d) for i in range(n)]

def tone(freq, dur, d=0.15, a=0.003, harm=((1, 1.0),), sweep=0.0):
    n = int(dur * SR); e = env(n, a, d); ph = 0.0; o = []
    for i in range(n):
        f = freq * (1 + sweep * i / n); ph += 2 * math.pi * f / SR
        o.append(e[i] * sum(h * math.sin(ph * k) for k, h in harm))
    return o

def mix(*tracks):
    n = max(len(t) for t, _ in tracks) if tracks and isinstance(tracks[0], tuple) else 0
    r = [0.0] * n
    for t, off in tracks:
        for i, s in enumerate(t):
            if off + i < n: r[off + i] += s
    return r

def mixat(parts):
    n = max(off + len(t) for t, off in parts)
    r = [0.0] * n
    for t, off in parts:
        for i, s in enumerate(t): r[off + i] += s
    return r

def noise(n): return [random.uniform(-1, 1) for _ in range(n)]

def lowpass(x, k):
    y = []; p = 0.0
    for s in x: p += k * (s - p); y.append(p)
    return y

# soft UI click (mouse): short filtered noise + low thump
n = int(0.07 * SR); e = env(n, 0.0005, 0.012)
write("click_soft", [a * b for a, b in zip(lowpass(noise(n), 0.35), e)] )
write("click_tick", mixat([(tone(2400, 0.04, 0.008), 0), (tone(900, 0.05, 0.015), 0)]))
write("pop", tone(520, 0.14, 0.05, 0.002, ((1, 1), (2, .2)), sweep=0.9))
write("bubble", tone(380, 0.22, 0.09, 0.004, ((1, 1), (2, .15)), sweep=1.6))
# whoosh
n = int(0.5 * SR); w = []
nz = noise(n)
for i in range(n):
    x = i / n; amp = math.sin(math.pi * x) ** 2
    w.append(nz[i] * amp)
write("whoosh", lowpass(lowpass(w, 0.12), 0.25 + 0.0), 0.8)
n = int(0.35 * SR); nz = noise(n)
write("swipe", lowpass([nz[i] * math.sin(math.pi * i / n) ** 3 for i in range(n)], 0.3), 0.8)
bell = ((1, 1), (2.76, .35), (5.4, .12))
write("chime", mixat([(tone(1318, 1.2, .35, .002, bell), 0), (tone(1760, 1.0, .3, .002, bell), int(.09 * SR))]))
write("success", mixat([(tone(f, 0.9, .22, .002, ((1, 1), (2, .25))), int(i * .1 * SR)) for i, f in enumerate([523, 659, 784, 1046])]))
write("notify", mixat([(tone(880, .5, .12, .002, bell), 0), (tone(1175, .7, .18, .002, bell), int(.12 * SR))]))
write("sparkle", mixat([(tone(1500 + 350 * i, .35, .08, .001, bell), int(i * .045 * SR)) for i in range(7)]))
write("thud", tone(70, .35, .1, .001, ((1, 1), (2, .4)), sweep=-0.4))
write("keystroke", mixat([(tone(1700, .03, .006), 0), (lowpass(noise(int(.03 * SR)), .3), 0)]))
write("ding", tone(1568, 1.0, .3, .002, bell))
write("drop", tone(900, .3, .1, .002, ((1, 1),), sweep=-0.7))

# ---- loading / progress sounds ----
def seq(parts): return mixat(parts)
# soft loading loop (2.4s): gentle rising pulses, loops seamlessly
parts=[]
for i,f in enumerate([523,587,659,784]):
    parts.append((tone(f, .5, .16, .01, ((1,1),(2,.2))), int(i*.6*SR)))
write("loading_loop", seq(parts), 0.55)
write("loading_start", mixat([(tone(660,.25,.08,.004,((1,1),(2,.2))),0),(tone(880,.3,.1,.004,((1,1),(2,.2))),int(.09*SR))]))
write("loading_done", mixat([(tone(f,.7,.2,.003,bell), int(i*.08*SR)) for i,f in enumerate([784,988,1318])]))
# progress ticks that speed up (1.6s)
parts=[]; t=0.0; gap=.22
while t<1.6:
    parts.append((tone(1200+int(t*500),.05,.012,.001,((1,1),(2,.3))), int(t*SR))); gap=max(.04,gap*.9); t+=gap
write("loading_progress", seq(parts), 0.7)
# ---- mouse wheel / scroll ----
def wheel_tick(freq=1900, vol=1.0):
    n=int(.028*SR); e=env(n,.0004,.006)
    body=[math.sin(2*math.pi*freq*i/SR)*e[i] for i in range(n)]
    nz=lowpass(noise(n),.4); return [vol*(b*.8+nz[i]*e[i]*.5) for i,b in enumerate(body)]
write("wheel_tick", wheel_tick(), 0.8)
write("wheel_soft", [x for x in wheel_tick(1300,.9)], 0.7)
# short scroll (0.9s): ease-in-out tick density
def wheel_run(dur, lo=7, hi=30):
    parts=[]; t=0.0
    while t<dur:
        x=t/dur; rate=lo+(hi-lo)*math.sin(math.pi*x)
        parts.append((wheel_tick(1500+random.uniform(-250,250), .55+.45*math.sin(math.pi*x)), int(t*SR))); t+=1.0/rate
    return mixat(parts)
write("wheel_scroll_short", wheel_run(.9), 0.8)
write("wheel_scroll_long", wheel_run(2.4,8,34), 0.8)
write("wheel_notch", mixat([(tone(2600,.015,.004),0),(wheel_tick(1100),0)]), 0.8)

# soft ambient pad (music bed, 20s loopable)
dur = 20; n = dur * SR; pad = [0.0] * n
for f, g in [(130.8, 1), (196.0, .7), (261.6, .6), (329.6, .45), (392.0, .35)]:
    d = random.uniform(0.15, 0.4)
    for i in range(n):
        t = i / SR
        pad[i] += g * math.sin(2 * math.pi * f * t + 0.8 * math.sin(2 * math.pi * d * t)) * (0.6 + 0.4 * math.sin(2 * math.pi * 0.05 * t + f))
fade = int(2 * SR)
for i in range(fade):
    k = i / fade; pad[i] *= k; pad[n - 1 - i] *= k
write("ambient_pad", pad, 0.5)
print("ok", len(os.listdir(out)), "files")

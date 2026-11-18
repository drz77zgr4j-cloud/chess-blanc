#!/usr/bin/env python3
"""Synthesises Blanc Chess's sound effects (wooden move clicks and soft UI tones) as 16-bit WAVs."""
import math, os, random, struct, wave, sys

RATE = 44100
OUT = sys.argv[1]
random.seed(7)

def write(name, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    with wave.open(os.path.join(OUT, name), 'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, s / peak * 0.9)) * 32767)) for s in samples))

def wood(dur=0.09, pitch=1.0, loud=1.0, second=None):
    """A wooden piece-on-board knock: damped resonances plus a short noise transient."""
    n = int(RATE * dur)
    modes = [(820 * pitch, 1.0, 38), (1640 * pitch, 0.45, 55), (2950 * pitch, 0.2, 80), (430 * pitch, 0.5, 30)]
    out = []
    for i in range(n):
        t = i / RATE
        s = sum(a * math.sin(2 * math.pi * f * t) * math.exp(-d * t * 10 / 3) for f, a, d in modes)
        s += (random.random() * 2 - 1) * 0.9 * math.exp(-t * 900)
        out.append(s * loud)
    if second:
        delay, p2 = second
        k = int(RATE * delay)
        tail = wood(dur, p2, loud * 0.8)
        out += [0.0] * max(0, k + len(tail) - len(out))
        for i, v in enumerate(tail):
            out[k + i] += v
    return out

def piano(freq, dur=1.1, vel=1.0, muted=False):
    """A soft felt-piano note: inharmonic partials, a padded hammer, a gentle decay."""
    n = int(RATE * dur)
    B = 0.0004
    partials = [(k, (0.9 ** (k - 1)) / k ** 0.6) for k in range(1, 9)]
    out = []
    damp = 7.5 if muted else 2.6
    for i in range(n):
        t = i / RATE
        attack = min(1.0, t / 0.012)                     # felt: no sharp click
        s = 0.0
        for k, a in partials:
            f = freq * k * math.sqrt(1 + B * k * k)
            s += a * math.sin(2 * math.pi * f * t) * math.exp(-t * damp * (1 + 0.35 * (k - 1)))
        s += (random.random() * 2 - 1) * 0.04 * math.exp(-t * 300)  # the felt's thump
        out.append(s * attack * vel)
    return out

def motif(notes, step=0.13, tail=0.9, muted=False):
    total = int(RATE * (step * (len(notes) - 1) + tail))
    out = [0.0] * total
    for j, (f, v) in enumerate(notes):
        start = int(RATE * step * j)
        note = piano(f, dur=tail, vel=v, muted=muted)
        for i, x in enumerate(note):
            if start + i < total:
                out[start + i] += x
    # fade the very end so nothing clicks
    fade = int(RATE * 0.05)
    for i in range(fade):
        out[-1 - i] *= i / fade
    return out

C4, E4, G4, A4, C5, E5, A2 = 261.63, 329.63, 392.0, 440.0, 523.25, 659.25, 110.0

write('move.wav', wood())
write('capture.wav', wood(dur=0.1, pitch=0.82, second=(0.028, 1.05)))
write('check.wav', wood(dur=0.1, pitch=1.25, second=(0.07, 1.4)))
write('castle.wav', wood(dur=0.09, second=(0.09, 0.95)))
write('right.wav', motif([(E5, 0.8)], tail=0.7))
write('wrong.wav', motif([(A2, 1.0)], tail=0.45, muted=True))
write('gained.wav', motif([(C4, 0.8), (G4, 0.9)], step=0.12, tail=1.0))
write('complete.wav', motif([(C4, 0.75), (G4, 0.8), (A4, 0.85), (C5, 1.0)], step=0.11, tail=1.2))
write('level.wav', motif([(C4, 0.75), (E4, 0.8), (G4, 0.85), (C5, 1.0)], step=0.1, tail=1.2))
write('lost.wav', motif([(E4, 0.8), (C4, 0.8)], step=0.16, tail=1.0))
write('next.wav', motif([(G4, 0.45)], tail=0.35, muted=True))
print(sorted(os.listdir(OUT)))

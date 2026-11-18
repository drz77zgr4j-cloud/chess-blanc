#!/usr/bin/env python3
"""One continuous picture across all nine store slots: a single 9×1320 canvas with a flowing colour wash,
bigger phones that cross from slot to slot, then sliced into nine 1320×2868 files."""
import json, sys, os
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import compose as C

W, H = C.W, C.H


def main(spec_path, shots_dir, out_dir):
    specs = json.load(open(spec_path))
    n = len(specs)
    PW = W * n
    canvas = Image.new('RGBA', (PW, H), C.GROUND + (255,))
    # the wash: one glow per slot, centred low behind its phone, plus a second high one, so the colour flows
    for i, s in enumerate(specs):
        base = i * W
        for gl in s.get('glows', []):
            C.glow(canvas, base + gl['x'], gl['y'], gl['r'], C.COLORS[gl['c']], gl.get('a', 0.4))
    # phones, left to right; each later one on top of the previous
    for i, s in enumerate(specs):
        base = i * W
        shot = C.clean_status_bar(Image.open(os.path.join(shots_dir, s['shot'])))
        screen_w = s.get('screen_w', 1200)
        frame, inset, scale = C.device(shot, screen_w)
        tilt = s.get('tilt', 0)
        cx = base + W // 2 + s.get('dx', 220)
        top = s.get('py', 660)
        if tilt:
            rot = frame.rotate(tilt, resample=Image.BICUBIC, expand=True)
            sh = Image.new('RGBA', rot.size, (0, 0, 0, 0))
            sh.putalpha(rot.split()[3].point(lambda v: int(v * 0.75)))
            sh = sh.filter(ImageFilter.GaussianBlur(50))
            ox = cx - rot.width // 2
            oy = top - (rot.height - frame.height) // 2
            canvas.alpha_composite(sh, (ox, oy + 50))
            canvas.alpha_composite(rot, (ox, oy))
        else:
            px = cx - frame.width // 2
            C.shadow(canvas, (px, top, px + frame.width, top + frame.height), int(screen_w * 0.14), 60, 0.8, 60)
            canvas.alpha_composite(frame, (px, top))
    # vignette per slot edge is wrong for a continuous image: one soft top/bottom darkening instead
    vig = Image.new('L', (1, H), 0)
    d = ImageDraw.Draw(vig)
    for y in range(H):
        t = y / H
        v = int(255 * min(1.0, 0.35 + 0.65 * (1 - abs(t - 0.5) * 2) ** 0.5))
        d.point((0, y), fill=v)
    vig = vig.resize((PW, H))
    dark = Image.new('RGBA', (PW, H), (0, 0, 0, 90))
    dark.putalpha(ImageChops.multiply(dark.split()[3], ImageChops.invert(vig)))
    canvas.alpha_composite(dark)
    noise = Image.effect_noise((PW, H), 18).convert('L')
    grain = Image.merge('RGBA', (noise, noise, noise, noise.point(lambda v: 14)))
    canvas.alpha_composite(grain)
    # headlines, one per slot, on top of everything
    for i, s in enumerate(specs):
        base = i * W
        C.text_block(canvas, s['headline'], s.get('tag'), s.get('text_top', 190), 'center', base + W // 2,
                     size=s.get('size', 140), tag_size=s.get('tag_size', 34))
    os.makedirs(out_dir, exist_ok=True)
    canvas.convert('RGB').resize((PW // 4, H // 4), Image.LANCZOS).save(os.path.join(out_dir, 'panorama.jpg'), quality=85)
    for i, s in enumerate(specs):
        canvas.crop((i * W, 0, (i + 1) * W, H)).convert('RGB').save(os.path.join(out_dir, s['name'] + '.png'))
        print(s['name'])


if __name__ == '__main__':
    main(*sys.argv[1:4])

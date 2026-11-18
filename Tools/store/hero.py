#!/usr/bin/env python3
"""Header (21:9) and search-results (3:2) assets for the App Store product page, from the same parts as the
screenshots: the colour wash, Pro-style phones fanned across, optional headline. Spec: a JSON list of canvases."""
import json, sys, os
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageFont
import compose as C


def render(spec, shots_dir, out_dir):
    W, H = spec['size']
    canvas = Image.new('RGBA', (W, H), C.GROUND + (255,))
    for gl in spec.get('glows', []):
        C.glow(canvas, gl['x'], gl['y'], gl['r'], C.COLORS[gl['c']], gl.get('a', 0.4))
    for ph in spec['phones']:
        shot = C.clean_status_bar(Image.open(os.path.join(shots_dir, ph['shot'])))
        frame, inset, scale = C.device(shot, ph['screen_w'])
        tilt = ph.get('tilt', 0)
        cx, top = ph['cx'], ph['top']
        if tilt:
            rot = frame.rotate(tilt, resample=Image.BICUBIC, expand=True)
            sh = Image.new('RGBA', rot.size, (0, 0, 0, 0))
            sh.putalpha(rot.split()[3].point(lambda v: int(v * 0.75)))
            sh = sh.filter(ImageFilter.GaussianBlur(40))
            ox = cx - rot.width // 2; oy = top - (rot.height - frame.height) // 2
            canvas.alpha_composite(sh, (ox, oy + 40))
            canvas.alpha_composite(rot, (ox, oy))
        else:
            px = cx - frame.width // 2
            C.shadow(canvas, (px, top, px + frame.width, top + frame.height), int(ph['screen_w'] * 0.14), 50, 0.8, 50)
            canvas.alpha_composite(frame, (px, top))
    # soft darkening at the edges, grain
    vig = Image.new('L', (W, H), 0)
    ImageDraw.Draw(vig).ellipse((-int(W * 0.2), -int(H * 0.5), int(W * 1.2), int(H * 1.5)), fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(int(min(W, H) * 0.25)))
    dark = Image.new('RGBA', (W, H), (0, 0, 0, 100))
    dark.putalpha(ImageChops.multiply(dark.split()[3], ImageChops.invert(vig)))
    canvas.alpha_composite(dark)
    noise = Image.effect_noise((W, H), 18).convert('L')
    canvas.alpha_composite(Image.merge('RGBA', (noise, noise, noise, noise.point(lambda v: 12))))
    if spec.get('headline'):
        t = spec['text']
        C.text_block(canvas, spec['headline'], spec.get('tag'), t['y'], t.get('align', 'left'), t['x'],
                     size=t.get('size', 150), tag_size=t.get('tag_size', 36))
    os.makedirs(out_dir, exist_ok=True)
    p = os.path.join(out_dir, spec['name'])
    canvas.convert('RGB').save(p, quality=95)
    return p


if __name__ == '__main__':
    spec_path, shots_dir, out_dir = sys.argv[1:4]
    for s in json.load(open(spec_path)):
        print(render(s, shots_dir, out_dir))

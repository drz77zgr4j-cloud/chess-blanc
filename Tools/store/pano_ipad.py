#!/usr/bin/env python3
"""The same continuous picture for the iPad 13" slot (2064x2752 x 9) from portrait iPad screenshots."""
import json, sys, os
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import compose as C
W, H = 2064, 2752
HERE = os.path.dirname(os.path.abspath(__file__))
SB_T = Image.open(os.path.join(HERE, 'ipad-sb-time.png')); SB_I = Image.open(os.path.join(HERE, 'ipad-sb-icons.png'))

def clean_ipad_bar(shot):
    shot = shot.convert('RGBA'); w, h = shot.size
    bar = int(h * 0.037)
    band = shot.crop((0, bar, w, bar + 6)).resize((w, 1), Image.BOX).resize((w, bar), Image.NEAREST)
    shot.paste(band, (0, 0))
    s = w / 2048
    for m, x0, y0 in ((SB_T, 20, 8), (SB_I, 1825, 8)):
        mm = m.resize((int(m.width * s), int(m.height * s)), Image.LANCZOS)
        white = Image.new('RGBA', mm.size, (255, 255, 255, 255)); white.putalpha(mm)
        shot.alpha_composite(white, (int(x0 * s), int(y0 * s)))
    return shot

def ipad_frame(shot, sw):
    sh = round(shot.height * sw / shot.width)
    screen = shot.resize((sw, sh), Image.LANCZOS)
    bezel = int(sw * 0.038); rim = int(sw * 0.006); inset = bezel + rim
    r_screen = int(sw * 0.028)
    fw, fh = sw + 2 * inset, sh + 2 * inset
    SS = 2
    big = Image.new('RGBA', (fw * SS, fh * SS), (0, 0, 0, 0)); g = ImageDraw.Draw(big)
    R = int(sw * 0.06) * SS
    grad = Image.linear_gradient('L').resize((fw * SS, fh * SS)).rotate(30, resample=Image.BICUBIC)
    rimimg = Image.composite(Image.new('RGBA', big.size, (96, 96, 102, 255)), Image.new('RGBA', big.size, (28, 28, 31, 255)), grad)
    mask = Image.new('L', big.size, 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, fw * SS - 1, fh * SS - 1), radius=R, fill=255)
    big.paste(rimimg, (0, 0), mask)
    g.rounded_rectangle((rim * SS, rim * SS, (fw - rim) * SS - 1, (fh - rim) * SS - 1), radius=R - rim * SS, fill=(0, 0, 0, 255))
    frame = big.resize((fw, fh), Image.LANCZOS)
    frame.paste(screen, (inset, inset), C.rounded_mask((sw, sh), r_screen, 3))
    return frame

def main(spec_path, shots_dir, out_dir):
    specs = json.load(open(spec_path)); n = len(specs); PW = W * n
    canvas = Image.new('RGBA', (PW, H), C.GROUND + (255,))
    for i, s in enumerate(specs):
        for gl in s['glows']:
            C.glow(canvas, i * W + int(gl['x'] * W / 1320), int(gl['y'] * H / 2868), int(gl['r'] * 1.5), C.COLORS[gl['c']], gl['a'])
    for i, s in enumerate(specs):
        raw = Image.open(os.path.join(shots_dir, s['name'] + '.png'))
        # Simulator captures already carry a clean 9:41 bar (simctl status_bar override); only device shots need the masks.
        shot = raw.convert('RGBA') if os.environ.get('NOCLEAN') else clean_ipad_bar(raw)
        frame = ipad_frame(shot, 1320)
        tilt = s.get('tilt', 0)
        cx = i * W + W // 2 + s.get('ipad_dx', 260); top = int(os.environ.get('IPAD_TOP', 720))
        rot = frame.rotate(tilt, resample=Image.BICUBIC, expand=True)
        sh = Image.new('RGBA', rot.size, (0, 0, 0, 0)); sh.putalpha(rot.split()[3].point(lambda v: int(v * 0.75)))
        sh = sh.filter(ImageFilter.GaussianBlur(60))
        ox = cx - rot.width // 2; oy = top - (rot.height - frame.height) // 2
        canvas.alpha_composite(sh, (ox, oy + 60)); canvas.alpha_composite(rot, (ox, oy))
    vig = Image.new('L', (1, H), 0); d = ImageDraw.Draw(vig)
    for y in range(H):
        t = y / H; d.point((0, y), fill=int(255 * min(1.0, 0.35 + 0.65 * (1 - abs(t - 0.5) * 2) ** 0.5)))
    vig = vig.resize((PW, H)); dark = Image.new('RGBA', (PW, H), (0, 0, 0, 90))
    dark.putalpha(ImageChops.multiply(dark.split()[3], ImageChops.invert(vig))); canvas.alpha_composite(dark)
    noise = Image.effect_noise((PW, H), 18).convert('L'); canvas.alpha_composite(Image.merge('RGBA', (noise, noise, noise, noise.point(lambda v: 14))))
    for i, s in enumerate(specs):
        C.text_block(canvas, s['headline'], s.get('tag'), 180, 'center', i * W + W // 2, size=s.get('size', 190), tag_size=46)
    os.makedirs(out_dir, exist_ok=True)
    canvas.convert('RGB').resize((PW // 6, H // 6), Image.LANCZOS).save(os.path.join(out_dir, 'panorama.jpg'), quality=85)
    for i, s in enumerate(specs):
        canvas.crop((i * W, 0, (i + 1) * W, H)).convert('RGB').save(os.path.join(out_dir, s['name'] + '.png')); print(s['name'])

if __name__ == '__main__': main(*sys.argv[1:4])

#!/usr/bin/env python3
"""Chess Blanc store screenshots (from the Blanc Notes tooling) — real-pixel composition.
Canvas 1320x2868 (6.9"). A cleaned real screenshot in a drawn iPhone Pro frame (titanium rim, black bezel,
Dynamic Island), a soft pink/blue wash on a near-black ground, a white two-line headline, optional small tag,
optional one lifted element (a crop of the same screenshot, enlarged, beside the phone)."""
import json, sys, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

W, H = 1320, 2868
SS = 2  # supersample for the frame
F = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fonts') + '/'
HEAD = F + 'Inter-Bold.ttf'
TAG = F + 'Inter-Bold.ttf'
STATUS = F + 'Inter-Bold.ttf'

GROUND = (10, 10, 13)
PINK = (255, 92, 122)
BLUE = (90, 200, 250)
ORANGE = (255, 150, 70)
GREEN = (80, 230, 170)
VIOLET = (130, 110, 255)
COLORS = {'pink': PINK, 'blue': BLUE, 'orange': ORANGE, 'green': GREEN, 'violet': VIOLET, 'teal': (40, 210, 200), 'ember': (255, 110, 60), 'coral': (255, 110, 120), 'magenta': (235, 60, 160), 'amber': (255, 179, 71)}


def rounded_mask(size, r, ss=1):
    w, h = size
    m = Image.new('L', (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), radius=r * ss, fill=255)
    return m.resize((w, h), Image.LANCZOS) if ss > 1 else m


def glow(canvas, cx, cy, radius, color, alpha):
    """A soft radial wash."""
    blur = int(radius * 0.5)
    pad = blur * 3
    size = radius * 2 + 2 * pad
    layer = Image.new('RGBA', (size, size), color + (0,))
    d = ImageDraw.Draw(layer)
    d.ellipse((pad, pad, pad + radius * 2 - 1, pad + radius * 2 - 1), fill=color + (int(255 * alpha),))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(layer, (int(cx - radius - pad), int(cy - radius - pad)))


SB_TIME = Image.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sb-time.png'))
SB_ICONS = Image.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sb-icons.png'))


def clean_status_bar(shot):
    """Replace the real status bar with the real 09:41 glyphs and full icons (masks lifted from a clean 9:41
    capture), laid on the shot's own top colour so a glow at the top survives."""
    shot = shot.convert('RGBA')
    w, h = shot.size
    bar_h = int(h * 0.054)
    band = shot.crop((0, bar_h, w, bar_h + 8)).resize((w, 1), Image.BOX).resize((w, bar_h), Image.NEAREST)
    shot.paste(band, (0, 0))
    s = w / 1320
    for mask, x0, y0 in ((SB_TIME, 160, 50), (SB_ICONS, 910, 50)):
        m = mask.resize((int(mask.width * s), int(mask.height * s)), Image.LANCZOS)
        white = Image.new('RGBA', m.size, (255, 255, 255, 255))
        white.putalpha(m)
        shot.alpha_composite(white, (int(x0 * s), int(y0 * s)))
    return shot


def device(shot, screen_w):
    """The shot in a Pro-style frame. Returns the RGBA frame image and the screen's offset inside it."""
    sw = screen_w
    sh = round(shot.height * sw / shot.width)
    screen = shot.resize((sw, sh), Image.LANCZOS)
    r_screen = int(sw * 0.125)
    bezel = int(sw * 0.014)
    rim = int(sw * 0.010)
    inset = bezel + rim
    fw, fh = sw + 2 * inset, sh + 2 * inset
    big = Image.new('RGBA', (fw * SS, fh * SS), (0, 0, 0, 0))
    g = ImageDraw.Draw(big)
    R = (r_screen + inset) * SS
    # rim: a titanium gradient — draw dark, then a lighter top-left edge
    # a diagonal titanium gradient, masked to the rim shape
    grad = Image.linear_gradient('L').resize((fw * SS, fh * SS)).rotate(30, resample=Image.BICUBIC, expand=False)
    light = Image.new('RGBA', big.size, (96, 96, 102, 255)); dark = Image.new('RGBA', big.size, (28, 28, 31, 255))
    rimimg = Image.composite(light, dark, grad)
    rimmask = Image.new('L', big.size, 0)
    ImageDraw.Draw(rimmask).rounded_rectangle((0, 0, fw * SS - 1, fh * SS - 1), radius=R, fill=255)
    big.paste(rimimg, (0, 0), rimmask)
    edge = Image.new('RGBA', big.size, (0, 0, 0, 0))
    ge = ImageDraw.Draw(edge)
    ge.rounded_rectangle((0, 0, fw * SS - 1, fh * SS - 1), radius=R, outline=(150, 150, 156, 160), width=1 * SS)
    big.alpha_composite(edge)
    # bezel
    g.rounded_rectangle((rim * SS, rim * SS, (fw - rim) * SS - 1, (fh - rim) * SS - 1), radius=R - rim * SS, fill=(0, 0, 0, 255))
    frame = big.resize((fw, fh), Image.LANCZOS)
    frame.paste(screen, (inset, inset), rounded_mask((sw, sh), r_screen, 3))
    # Dynamic Island
    d = ImageDraw.Draw(frame)
    iw, ih = int(sw * 0.285), int(sw * 0.084)
    ix = inset + (sw - iw) // 2; iy = inset + int(sw * 0.026)
    d.rounded_rectangle((ix, iy, ix + iw, iy + ih), radius=ih // 2, fill=(0, 0, 0, 255))
    # buttons on the rim
    bx = 0; by0 = inset + int(sh * 0.14)
    d.rounded_rectangle((bx - 3, by0, bx + 2, by0 + int(sh * 0.035)), radius=2, fill=(70, 70, 74, 255))
    d.rounded_rectangle((bx - 3, by0 + int(sh * 0.055), bx + 2, by0 + int(sh * 0.12)), radius=2, fill=(70, 70, 74, 255))
    d.rounded_rectangle((bx - 3, by0 + int(sh * 0.135), bx + 2, by0 + int(sh * 0.20)), radius=2, fill=(70, 70, 74, 255))
    d.rounded_rectangle((fw - 3, by0 + int(sh * 0.06), fw + 2, by0 + int(sh * 0.16)), radius=2, fill=(70, 70, 74, 255))
    return frame, inset, sw / shot.width


def shadow(canvas, box, radius, blur, alpha, dy):
    x0, y0, x1, y1 = box
    pad = blur * 3
    layer = Image.new('RGBA', (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle((pad, pad, pad + x1 - x0, pad + y1 - y0), radius=radius, fill=(0, 0, 0, int(255 * alpha)))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(layer, (x0 - pad, y0 - pad + dy))


def text_block(canvas, headline, tag, top, align='center', x=None, width=None, size=132, tag_size=34):
    d = ImageDraw.Draw(canvas)
    y = top
    cx = W // 2 if x is None else x
    if tag:
        f = ImageFont.truetype(TAG, tag_size)
        t = tag.upper()
        # letterspaced: draw char by char
        spacing = tag_size * 0.16
        widths = [d.textlength(c, font=f) for c in t]
        tw = sum(widths) + spacing * (len(t) - 1)
        padx, pady = int(tag_size * 1.0), int(tag_size * 0.5)
        bw, bh = tw + 2 * padx, tag_size + 2 * pady
        if align == 'center': bx = cx - bw / 2
        elif align == 'left': bx = cx
        else: bx = cx - bw
        d.rounded_rectangle((bx, y, bx + bw, y + bh), radius=bh / 2, outline=(255, 255, 255, 80), width=2)
        xx = bx + padx
        for c, cw in zip(t, widths):
            d.text((xx, y + bh / 2), c, font=f, fill=(205, 205, 210, 255), anchor='lm')
            xx += cw + spacing
        y += bh + int(size * 0.32)
    f = ImageFont.truetype(HEAD, size)
    lines = headline.split('\n')
    lh = int(size * 1.08)
    for i, line in enumerate(lines):
        if align == 'center': anchor, tx = 'ma', cx
        elif align == 'left': anchor, tx = 'la', cx
        else: anchor, tx = 'ra', cx
        d.text((tx, y + i * lh), line, font=f, fill=(255, 255, 255, 255), anchor=anchor)
    return y + len(lines) * lh


def compose(spec, shots_dir, out_path):
    canvas = Image.new('RGBA', (W, H), GROUND + (255,))
    for gl in spec.get('glows', []):
        glow(canvas, gl['x'], gl['y'], gl['r'], COLORS[gl['c']], gl.get('a', 0.4))
    if spec.get('panels'):
        # frameless close-ups: the interface itself is the artwork
        for pn in spec['panels']:
            src = Image.open(os.path.join(shots_dir, pn['shot'])).convert('RGBA')
            x0, y0, x1, y1 = pn['box']
            crop = src.crop((x0, y0, x1, y1))
            pw = pn.get('width', 1240)
            ph = int((y1 - y0) * pw / (x1 - x0))
            crop = crop.resize((pw, ph), Image.LANCZOS)
            r = pn.get('radius', 64)
            m = rounded_mask((pw, ph), r, 3)
            piece = Image.new('RGBA', (pw, ph), (0, 0, 0, 0)); piece.paste(crop, (0, 0), m)
            ImageDraw.Draw(piece).rounded_rectangle((0, 0, pw - 1, ph - 1), radius=r, outline=(255, 255, 255, 40), width=2)
            px_ = pn.get('x', (W - pw) // 2); py_ = pn['y']
            shadow(canvas, (px_, py_, px_ + pw, py_ + ph), r, 50, 0.8, 50)
            canvas.alpha_composite(piece, (px_, py_))
        finish(canvas, spec, out_path)
        return out_path
    shot = Image.open(os.path.join(shots_dir, spec['shot']))
    shot = clean_status_bar(shot)
    tilt = spec.get('tilt', 0)
    screen_w = spec.get('screen_w', 1100)
    frame, inset, scale = device(shot, screen_w)
    px = spec.get('px', (W - frame.width) // 2)
    py = spec.get('py', 720)
    # shadow + frame (rotated if asked)
    if tilt:
        rot = frame.rotate(tilt, resample=Image.BICUBIC, expand=True)
        sh = Image.new('RGBA', rot.size, (0, 0, 0, 0))
        a = rot.split()[3].point(lambda v: int(v * 0.75))
        sh.putalpha(a)
        sh = sh.filter(ImageFilter.GaussianBlur(50))
        ox = px - (rot.width - frame.width) // 2
        oy = py - (rot.height - frame.height) // 2
        canvas.alpha_composite(sh, (ox, oy + 50))
        canvas.alpha_composite(rot, (ox, oy))
    else:
        shadow(canvas, (px, py, px + frame.width, py + frame.height), int(screen_w * 0.14), 60, 0.8, 60)
        canvas.alpha_composite(frame, (px, py))
    # lifted element
    lift = spec.get('lift')
    if lift and not tilt:
        x0, y0, x1, y1 = lift['box']
        crop = shot.crop((x0, y0, x1, y1))
        k = scale * lift.get('scale', 1.28)
        cw, ch = int((x1 - x0) * k), int((y1 - y0) * k)
        crop = crop.resize((cw, ch), Image.LANCZOS)
        r = int(lift.get('radius', 0.5) * min(cw, ch)) if lift.get('radius', 0.5) <= 1 else lift['radius']
        m = rounded_mask((cw, ch), r, 3)
        piece = Image.new('RGBA', (cw, ch), (0, 0, 0, 0)); piece.paste(crop, (0, 0), m)
        # a hairline
        ImageDraw.Draw(piece).rounded_rectangle((0, 0, cw - 1, ch - 1), radius=r, outline=(255, 255, 255, 45), width=2)
        # where: at the element's own y on the phone, pushed out past the phone's edge
        ey = py + inset + int(y0 * scale) - int((ch - (y1 - y0) * scale) / 2) + lift.get('dy', 0)
        side = lift.get('side', 'right')
        if side == 'right': ex = px + frame.width - cw + lift.get('out', 120)
        elif side == 'left': ex = px - lift.get('out', 120)
        else: ex = (W - cw) // 2
        shadow(canvas, (ex, ey, ex + cw, ey + ch), r, 40, 0.75, 36)
        canvas.alpha_composite(piece, (ex, ey))
    finish(canvas, spec, out_path)
    return out_path


def finish(canvas, spec, out_path):
    # vignette and a touch of grain, so the ground reads as a surface, not a flat fill
    vig = Image.new('L', (W, H), 0)
    ImageDraw.Draw(vig).ellipse((-int(W * 0.35), -int(H * 0.25), int(W * 1.35), int(H * 1.25)), fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(320))
    dark = Image.new('RGBA', (W, H), (0, 0, 0, 110))
    dark.putalpha(ImageChops.multiply(dark.split()[3], ImageChops.invert(vig)))
    canvas.alpha_composite(dark)
    import random
    rnd = random.Random(7)
    noise = Image.effect_noise((W, H), 18).convert('L')
    grain = Image.new('RGBA', (W, H), (128, 128, 128, 0)); grain.putalpha(noise.point(lambda v: 14))
    g2 = Image.merge('RGBA', (noise, noise, noise, grain.split()[3]))
    canvas.alpha_composite(g2)
    text_block(canvas, spec['headline'], spec.get('tag'), spec.get('text_top', 190), spec.get('align', 'center'),
               spec.get('text_x'), size=spec.get('size', 140), tag_size=spec.get('tag_size', 34))
    canvas.convert('RGB').save(out_path, quality=95)


if __name__ == '__main__':
    spec_path, shots_dir, out_dir = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    specs = json.load(open(spec_path))
    for s in specs:
        print(compose(s, shots_dir, os.path.join(out_dir, s['name'] + '.png')))

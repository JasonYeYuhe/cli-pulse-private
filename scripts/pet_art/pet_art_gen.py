#!/usr/bin/env python3
"""Pulse Cat — in-house parametric line-art generator (v1.42 M2).

Original hand-authored vector line-art. NOT traced from any meme image; the six
forms capture GENERIC cat archetype energy (loaf pose, flat smile, O-mouth,
stretched body, head-tilt, keyboard-paws). One shared base cat + per-(form,state,
frame) parameter deltas → frame-to-frame consistency. Emits SVG; the export
script rasterizes to PetAssets/ PNG @1x/@2x.
"""
import math

STROKE = 14
VIEW = 512

def _p(pts):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)

class Cat:
    def __init__(self):
        self.paths = []   # (d, filled)
        self.circles = [] # (cx,cy,r,filled)
        self.raws = []    # raw <g>..</g> fragments (already stroked)

    def stroke_path(self, d): self.paths.append((d, False))
    def fill_path(self, d): self.paths.append((d, True))
    def raw(self, frag): self.raws.append(frag)
    def eye(self, cx, cy, r=12, closed=False):
        if closed:
            self.stroke_path(f"M{cx-r-2} {cy} q{r+2} {r} {2*r+4} 0")
        else:
            self.circles.append((cx, cy, r, True))
    def inner(self):
        body = []
        for d, filled in self.paths:
            if filled:
                body.append(f'<path d="{d}" fill="#000" stroke="none"/>')
            else:
                body.append(f'<path d="{d}"/>')
        for cx, cy, r, filled in self.circles:
            fill = '#000' if filled else 'none'
            body.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"/>')
        body.extend(self.raws)
        return "\n    ".join(body)
    def svg(self):
        inner = self.inner()
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {VIEW} {VIEW}">\n'
                f'  <g fill="none" stroke="#000" stroke-width="{STROKE}" '
                f'stroke-linecap="round" stroke-linejoin="round">\n    {inner}\n  </g>\n</svg>\n')


def ears(c, cx, cy, spread=86, h=60, flop=None):
    # flop: None | 'left' | 'right' -> one ear tilts sideways (huh)
    lx, rx = cx - spread, cx + spread
    ly = ry = cy
    if flop == 'right':
        c.stroke_path(f"M{lx} {ly} L{lx-20} {ly-h} L{lx+44} {ly-h+22} Z")
        c.stroke_path(f"M{rx} {ry} L{rx+46} {ry-24} L{rx+8} {ry-h+16} Z")  # sideways
    else:
        c.stroke_path(f"M{lx} {ly} L{lx-20} {ly-h} L{lx+44} {ly-h+22} Z")
        c.stroke_path(f"M{rx} {ry} L{rx+20} {ry-h} L{rx-44} {ry-h+22} Z")


def face(c, cx, cy, eyes='dot', mouth='smile', eye_r=12, teary=False):
    ex = 36
    if eyes == 'closed':
        c.eye(cx-ex, cy-6, eye_r, closed=True); c.eye(cx+ex, cy-6, eye_r, closed=True)
    elif eyes == 'half':
        c.stroke_path(f"M{cx-ex-16} {cy-6} h32"); c.stroke_path(f"M{cx+ex-16} {cy-6} h32")
    elif eyes == 'wide':
        c.circles.append((cx-ex, cy-6, eye_r+8, False)); c.circles.append((cx+ex, cy-6, eye_r+8, False))
        c.circles.append((cx-ex, cy-6, 5, True)); c.circles.append((cx+ex, cy-6, 5, True))
    else:  # dot
        c.eye(cx-ex, cy-6, eye_r); c.eye(cx+ex, cy-6, eye_r)
    if teary:
        c.stroke_path(f"M{cx-ex-6} {cy+8} q-8 20 4 24"); c.stroke_path(f"M{cx+ex+6} {cy+8} q8 20 -4 24")
    # nose
    c.fill_path(f"M{cx} {cy+18} l-8 10 h16 Z")
    my = cy+28
    if mouth == 'O':
        c.circles.append((cx, my+8, 15, False))
    elif mouth == 'flat':   # unsettlingly wide flat smile (polite)
        c.stroke_path(f"M{cx-58} {my} q58 30 116 0")
    elif mouth == 'open':   # effort (smash)
        c.circles.append((cx, my+6, 12, False)); c.stroke_path(f"M{cx-14} {my-2} h28")
    elif mouth == 'tiny':
        c.circles.append((cx, my+4, 6, False))
    else:  # smile
        c.stroke_path(f"M{cx} {my-4} q-16 14 -30 4"); c.stroke_path(f"M{cx} {my-4} q16 14 30 4")
    # whiskers
    c.stroke_path(f"M{cx-106} {cy+10} h40"); c.stroke_path(f"M{cx+66} {cy+10} h40")


def zzz(c, x, y):
    for i, s in enumerate((22, 16, 11)):
        ox, oy = x + i*20, y - i*22
        c.stroke_path(f"M{ox} {oy} h{s} l-{s} {s} h{s}")


def emphasis(c, cx, cy):
    c.stroke_path(f"M{cx-150} {cy-30} l-26 -10"); c.stroke_path(f"M{cx+150} {cy-30} l26 -10")


# ---- form drawers: (state, frame) -> Cat ----

def draw(form, state, frame):
    c = Cat()
    hx, hy = 256, 196
    sleeping = (state == 'sleep')

    if form == 'loaf':
        # cat compressed into a bread-loaf: rounded-rectangle body, ears on top,
        # paws tucked (invisible), serene content face.
        flat = 22 if sleeping else 0
        ears(c, 256, 244 + flat)
        c.stroke_path(f"M150 {306+flat} Q150 252 210 248 H302 Q362 252 362 {306+flat} "
                      f"V366 Q362 408 302 412 H210 Q150 408 150 366 Z")
        e = 'closed' if (sleeping or frame == 1) else 'half'
        m = 'tiny' if sleeping else 'smile'
        face(c, 256, 300 + flat, eyes=e, mouth=m)
        if sleeping:
            zzz(c, 372, 250)
        elif state == 'active':
            c.stroke_path("M232 224 q-10 -30 8 -48")
            if frame == 1: c.stroke_path("M280 224 q10 -30 -8 -48")

    elif form == 'polite':
        base_cat(c, hx, hy, sleeping)
        if sleeping:
            face(c, hx, hy, eyes='closed', mouth='flat'); zzz(c, 360, 150)
        else:
            wider = 58 + (18 if frame == 1 else 0)
            face(c, hx, hy, eyes='dot', mouth='flat')
            c.stroke_path("M226 452 q-6 -30 0 -50"); c.stroke_path("M286 452 q6 -30 0 -50")  # paws together
            if state == 'active':
                py = 300 if frame == 1 else 340
                c.stroke_path(f"M330 400 q60 -20 44 -{440-py}")  # raised wave paw

    elif form == 'smash':
        base_cat(c, hx, hy-6, sleeping)
        if sleeping:
            c.stroke_path("M176 452 h160")  # slumped on keyboard
            face(c, hx, hy+30, eyes='closed', mouth='tiny'); zzz(c, 360, 250)
        else:
            m = 'open' if (state == 'active' and frame == 1) else 'smile'
            face(c, hx, hy-6, eyes='wide', mouth=m)
            # tiny keyboard
            c.stroke_path("M176 452 h160 v34 h-160 Z")
            for gx in range(196, 330, 22): c.stroke_path(f"M{gx} 460 v18")
            pl = 452 if frame == 0 else 470
            c.stroke_path(f"M214 430 v{pl-430}"); c.stroke_path(f"M298 430 v{(470 if frame==0 else 452)-430}")
            if state == 'active':
                c.stroke_path("M196 420 l-14 -12"); c.stroke_path("M316 420 l14 -12")

    elif form == 'pop':
        base_cat(c, hx, hy, sleeping)
        if sleeping:
            face(c, hx, hy, eyes='closed', mouth='tiny'); zzz(c, 360, 150)
        else:
            m = 'O' if (frame == 1 or state == 'active') else 'smile'
            eyes = 'wide' if m == 'O' else 'dot'
            face(c, hx, hy, eyes=eyes, mouth=m)
            if state == 'active' and frame == 0: emphasis(c, hx, hy)

    elif form == 'long':
        # comically elongated horizontal tube; normal head on the left.
        if sleeping:
            # coiled into a spiral (cinnamon-roll)
            c.stroke_path("M256 320 m-70 0 a70 70 0 1 1 140 0 a44 44 0 1 1 -88 0 a20 20 0 1 1 40 0")
            ears(c, 200, 268, spread=44, h=40)
            face(c, 200, 300, eyes='closed', mouth='tiny'); zzz(c, 360, 250)
        else:
            arch = 26 if (state == 'active' and frame == 1) else 0
            top = 292 - arch // 2
            # long tube body
            c.stroke_path(f"M196 {top} H358 Q398 {top} 398 {top+34} Q398 {top+68} 358 {top+68} H196")
            hy2 = 300
            c.circles.append((150, hy2, 80, False))              # head
            ears(c, 150, hy2 - 52, spread=48, h=46)
            face(c, 150, hy2 - 2, eyes='half', mouth='smile')
            # four legs
            legs = (214, 250, 322, 358) if state != 'active' else (206, 258, 314, 366)
            for lx in legs: c.stroke_path(f"M{lx} {top+68} v38")
            c.stroke_path(f"M398 {top+30} c44 -6 58 -34 38 -60")  # tail

    elif form == 'huh':
        if sleeping:
            base_cat(c, hx, hy, True)
            hd = Cat(); hd.circles.append((256, 300, 92, False)); ears(hd, 256, 300)
            face(hd, 256, 300, eyes='closed', mouth='tiny')
            c.raw(f'<g transform="rotate(8 256 320)">{hd.inner()}</g>')
            zzz(c, 372, 250)
        else:
            # upright body; the whole HEAD tilts (the classic "huh?").
            c.stroke_path("M176 268 C150 330 150 400 176 430 C210 452 302 452 336 430 C362 400 362 330 336 268")
            c.stroke_path("M214 452 q-6 -26 0 -44"); c.stroke_path("M298 452 q6 -26 0 -44")
            c.stroke_path("M336 420 c46 8 66 -26 44 -60")
            tilt = 18 if frame == 0 else -18
            hd = Cat()
            hd.circles.append((256, 196, 92, False))
            ears(hd, 256, 196, flop='right')
            face(hd, 256, 196, eyes='wide', mouth='tiny')
            c.raw(f'<g transform="rotate({tilt} 256 220)">{hd.inner()}</g>')
            if state == 'active':
                c.stroke_path("M398 150 q30 -24 2 -44 q-22 -16 -34 6")   # "?"
                c.circles.append((392, 170, 6, True))
    return c.svg()


def base_cat(c, cx, cy, sleeping, tilt=0):
    """Standard sitting cat: ears, head, body, paws, tail."""
    if sleeping:
        c.stroke_path("M150 300 q106 70 212 0 q26 60 -14 92 q-92 34 -184 0 q-40 -32 -14 -92")
        ears(c, cx, 300)
        return
    ears(c, cx, cy, flop='right' if tilt else None)
    c.circles.append((cx, cy, 96, False))                       # head
    c.stroke_path("M176 268 C150 330 150 400 176 430 C210 452 302 452 336 430 C362 400 362 330 336 268")
    c.stroke_path("M214 452 q-6 -26 0 -44"); c.stroke_path("M298 452 q6 -26 0 -44")  # paws
    c.stroke_path("M336 420 c46 8 66 -26 44 -60")              # tail


def egg_body(c, dx=0, lift=0, ear=False):
    # upright egg, narrow top / round bottom, optional ear bumps + lifted cap
    cx = 256 + dx
    c.stroke_path(f"M{cx} {150-lift} C{cx-78} {150-lift} {cx-92} 300 {cx-92} 336 "
                  f"C{cx-92} 410 {cx+92} 410 {cx+92} 336 C{cx+92} 300 {cx+78} {150-lift} {cx} {150-lift} Z")
    if ear:
        c.stroke_path(f"M{cx-40} {150-lift} l-8 -34 l30 18")
        c.stroke_path(f"M{cx+40} {150-lift} l8 -34 l-30 18")


def draw_egg(state):
    c = Cat()
    if state == 'idle_0':
        egg_body(c)
    elif state == 'idle_1':
        # mid-wiggle: whole egg tilted ~8 degrees
        e = Cat(); egg_body(e)
        c.raw(f'<g transform="rotate(8 256 380)">{e.inner()}</g>')
    elif state == 'crack1':
        egg_body(c)
        c.stroke_path("M214 214 l18 14 l-14 16 l20 12")   # small zigzag crack near top
    elif state == 'crack2':
        egg_body(c)
        c.stroke_path("M206 210 l20 16 l-16 18 l22 14 l-14 18 l18 12")  # crack spreads down
        c.circles.append((290, 250, 11, False)); c.circles.append((290, 250, 4, True))  # peeking eye
    elif state == 'crack3':
        egg_body(c, lift=18, ear=True)
        # jagged separation line across the middle
        c.stroke_path("M164 262 l26 -14 l24 16 l26 -16 l24 16 l26 -14 l24 14")
    elif state == 'hatch_burst':
        for ang in range(0, 360, 30):
            import math as _m
            a = _m.radians(ang)
            x1, y1 = 256 + 70*_m.cos(a), 256 + 70*_m.sin(a)
            x2, y2 = 256 + 118*_m.cos(a), 256 + 118*_m.sin(a)
            c.stroke_path(f"M{x1:.0f} {y1:.0f} L{x2:.0f} {y2:.0f}")
        for sx, sy in ((150, 150), (372, 150), (256, 372)):
            c.fill_path(f"M{sx} {sy-14} l4 10 l10 0 l-8 7 l3 10 l-9 -6 l-9 6 l3 -10 l-8 -7 l10 0 Z")
    return c.svg()


EGG_STATES = ['idle_0', 'idle_1', 'crack1', 'crack2', 'crack3', 'hatch_burst']
FORMS = ['loaf', 'polite', 'smash', 'pop', 'long', 'huh']
# (state, [frames])
FRAMES = {'idle': [0, 1], 'active': [0, 1], 'sleep': [0]}

if __name__ == '__main__':
    import sys, os
    outdir = sys.argv[1] if len(sys.argv) > 1 else '.'
    n = 0
    for form in FORMS:
        for state, frames in FRAMES.items():
            for f in frames:
                os.makedirs(os.path.join(outdir, form), exist_ok=True)
                with open(os.path.join(outdir, form, f"{state}_{f}.svg"), 'w') as fh:
                    fh.write(draw(form, state, f))
                n += 1
    os.makedirs(os.path.join(outdir, 'egg'), exist_ok=True)
    for st in EGG_STATES:
        with open(os.path.join(outdir, 'egg', f"{st}.svg"), 'w') as fh:
            fh.write(draw_egg(st))
        n += 1
    print("generated", n, "frames")

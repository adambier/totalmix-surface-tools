#!/usr/bin/env python3
"""Performance Bridge's app icon and menu-bar glyph, as SVG, from one set of geometry.

Design "1q‴" (chosen 2026-10-30): a single-tower, self-anchored suspension span (after the outline
of the San Francisco-Oakland Bay Bridge's east span, stylized), whose hangers are fader slots, at
night over water. The cables are parabolas with vertical axes and their low points at the deck
anchors (the shape of a cable carrying an evenly spread deck); the tower is drawn two to three
times taller than the real one so the bridge reads at small sizes.

Writes, next to this script:
  master/        full-bleed 1024 x 1024 layers for the macOS 26 icon format (Icon Composer):
                 1-sky.svg (and 1-sky-dark.svg for the dark appearance), 2-reflection.svg,
                 3-bridge.svg, 4-faders.svg, and composite.svg
  legacy/        shaped icons with a drop shadow, for an .icns: large.svg (128 px and up, with
                 the reflection), medium.svg (64 px), px32.svg and px16.svg (drawn on the pixel
                 grid)
  menubar/       MenuBarIcon.svg, a one-color template glyph (20 x 18 points), and in
                 alternatives/ the bridge glyph kept for later

Standard library only. Render the SVGs to PNG with any SVG renderer (render.js uses Chromium
through Playwright) and build the .icns with `iconutil -c icns AppIcon.iconset` on a Mac.
"""

import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))

# Colors
SKY = ("#1b2f52", "#0d1830", "#060b17")  # top, 60 %, bottom
SKY_DARK = ("#111d3b", "#081024", "#02050e")  # the dark appearance: a little darker, more midnight (Adam)
AMBER = "#ffb13d"                         # the cables and tower; also the app's accent color
DECK_LARGE = "#33466a"
DECK_SMALL = "#8597bb"                    # lighter, so the deck reads at 64 px and below
HANGER = "#3d5276"
CAP = "#f3eee4"

# Geometry on the legacy 1024 grid, where the icon's body is the 824 x 824 square at (100, 100).
TOWER_X, TOWER_TOP = 650, 205
CABLE_TOP = TOWER_TOP + 25
DECK_Y = 605          # bottom of the hangers; the deck line is drawn at DECK_LINE
DECK_LINE = 620
ANCHOR_L, ANCHOR_R = 170, 860
LARGE_SHIFT = -50     # the large icon raises the waterline 50 units, for the reflection

# Fader caps for each rendition: (x, cap top y); hanger tops follow from the cable.
CAPS_LARGE = [(365, 565), (425, 547), (485, 512), (545, 416), (605, 377), (700, 439), (750, 550)]
CAP_LARGE = (52, 36)
CAPS_MEDIUM = [(420, 565), (520, 454), (600, 344), (710, 482)]
CAP_MEDIUM = (66, 36)


def cable_y(x):
    """The cable's height at x: a vertical-axis parabola from the tower top down to each anchor,
    with its low point at the anchor (y grows downward)."""
    if x <= TOWER_X:
        u = (x - ANCHOR_L) / (TOWER_X - ANCHOR_L)
    else:
        u = (ANCHOR_R - x) / (ANCHOR_R - TOWER_X)
    return DECK_Y - (DECK_Y - CABLE_TOP) * u * u


def cable_paths():
    """The two cables as quadratic Béziers whose control points sit halfway along x, at the
    anchors' height: exactly the parabolas of cable_y."""
    left = "M %d %d Q %.1f %d %d %d" % (TOWER_X, CABLE_TOP, (TOWER_X + ANCHOR_L) / 2, DECK_Y, ANCHOR_L, DECK_Y)
    right = "M %d %d Q %.1f %d %d %d" % (TOWER_X, CABLE_TOP, (TOWER_X + ANCHOR_R) / 2, DECK_Y, ANCHOR_R, DECK_Y)
    return left, right


def tower(k):
    return '<polygon points="%.1f,%d %.1f,%d %.1f,612 %.1f,612" fill="%s"></polygon>' % (
        TOWER_X - 12 * k, TOWER_TOP, TOWER_X + 12 * k, TOWER_TOP, TOWER_X + 24 * k, TOWER_X - 24 * k, AMBER)


def bridge(k, deck_color, deck_width, caps, with_deck=True):
    """Deck, hangers, cables, and tower (no caps)."""
    left, right = cable_paths()
    out = []
    if with_deck:
        out.append('<line x1="160" y1="%d" x2="864" y2="%d" stroke="%s" stroke-width="%.1f" stroke-linecap="round"></line>'
                   % (DECK_LINE, DECK_LINE, deck_color, deck_width))
    out.append('<g stroke="%s" stroke-width="%.1f" stroke-linecap="round">' % (HANGER, 14 * k) + "".join(
        '<line x1="%s" y1="%.0f" x2="%s" y2="%d"></line>' % (x, cable_y(x) + 10, x, DECK_Y) for x, _ in caps) + "</g>")
    out.append('<g fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round"><path d="%s"></path><path d="%s"></path></g>'
               % (AMBER, 24 * k, left, right))
    out.append(tower(k))
    return "\n".join(out)


def flat_caps(caps, size):
    w, h = size
    return '<g fill="%s">' % CAP + "".join(
        '<rect x="%.1f" y="%d" width="%d" height="%d" rx="%d"></rect>' % (x - w / 2, y, w, h, h // 4) for x, y in caps) + "</g>"


def shaded_caps(caps, size, face_id):
    """Caps with a shadow, a light face, a highlight, and a center line (128 px and up)."""
    w, h = size
    rects = lambda dy, fill, extra="": "".join(
        '<rect x="%.1f" y="%d" width="%d" height="%d" rx="%d"%s></rect>' % (x - w / 2, y + dy, w, h, h // 4, extra) for x, y in caps)
    out = ['<g fill="#03060d" fill-opacity="0.45">' + rects(8, None) + "</g>",
           '<g fill="url(#%s)">' % face_id + rects(0, None) + "</g>",
           '<g fill="#ffffff" fill-opacity="0.55">' + "".join(
               '<rect x="%.1f" y="%d" width="%d" height="9" rx="4.5"></rect>' % (x - w / 2 + 6, y + 5, w - 12) for x, y in caps) + "</g>",
           '<g stroke="#5b5a57" stroke-width="5" stroke-linecap="round">' + "".join(
               '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f"></line>' % (x - w / 2 + 12, y + h * 0.65, x + w / 2 - 12, y + h * 0.65)
               for x, y in caps) + "</g>"]
    return "\n".join(out)


CAP_FACE = '<linearGradient id="%s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fbf8f1"></stop><stop offset="1" stop-color="#d9d2c4"></stop></linearGradient>'
SKY_GRADIENT = ('<linearGradient id="%s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="' + SKY[0] +
                '"></stop><stop offset="0.6" stop-color="' + SKY[1] + '"></stop><stop offset="1" stop-color="' + SKY[2] + '"></stop></linearGradient>')


def water(prefix):
    """The reflection as plain vector shapes (no filter): the bridge mirrored at the deck line, cut
    into horizontal strips that are shifted sideways and fade with depth. Returns the clip paths and
    the strips. (Dark wave lines across the water were tried and dropped: Adam, 2026-10-30.)"""
    mirrored = bridge(1, DECK_LARGE, 22, CAPS_LARGE, with_deck=False) + "\n" + flat_caps(CAPS_LARGE, CAP_LARGE)
    defs, strips = [], []
    strip_h, top = 8, DECK_LINE
    count = 36
    for i in range(count):
        y0 = top + i * strip_h
        depth = i / count
        dx = (4 + 14 * depth) * (math.sin(i * 0.9) + 0.6 * math.sin(i * 2.3 + 1.0))
        opacity = 0.55 * (1 - depth) ** 1.4
        cid = "%sstrip%d" % (prefix, i)
        defs.append('<clipPath id="%s"><rect x="0" y="%d" width="1024" height="%d"></rect></clipPath>' % (cid, y0, strip_h))
        strips.append('<g clip-path="url(#%s)" opacity="%.3f"><g transform="translate(%.1f %d) scale(1 -1)">%s</g></g>'
                      % (cid, opacity, dx, 2 * DECK_LINE, mirrored))
    return "\n".join(defs), "\n".join(strips)


def superellipse(cx, cy, half, n=5.0, steps=256):
    """An approximation of Apple's continuous-corner icon shape: a superellipse with exponent 5.
    (An approximation, not Apple's template; use the template from Apple Design Resources for the
    final legacy art if it differs visibly.)"""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + half * math.copysign(abs(c) ** (2 / n), c)
        y = cy + half * math.copysign(abs(s) ** (2 / n), s)
        pts.append("%.2f,%.2f" % (x, y))
    return "M " + " L ".join(pts) + " Z"


BODY = superellipse(512, 512, 412)


def svg(size, body, defs=""):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">\n<defs>\n%s\n</defs>\n%s\n</svg>\n'
            % (size, size, size, size, defs, body))


# The master layers fill the whole 1024 canvas (the system applies the icon shape; an inference
# from Icon Composer's full-canvas layers, to check there), so the art drawn for the 824 body is
# scaled up about the canvas center.
# Scaled a little less than the full 1024/824, to keep the tower top clear of the shape's edge.
MASTER_SCALE = 1.15
MASTER = 'transform="matrix(%.5f 0 0 %.5f %.3f %.3f)"' % (MASTER_SCALE, MASTER_SCALE, 512 - 512 * MASTER_SCALE, 512 - 512 * MASTER_SCALE)
SHIFT = 'transform="translate(0 %d)"' % LARGE_SHIFT


def master_layers():
    sky = svg(1024, '<rect width="1024" height="1024" fill="url(#sky)"></rect>', SKY_GRADIENT % "sky")
    dark = SKY_GRADIENT.replace(SKY[0], SKY_DARK[0]).replace(SKY[1], SKY_DARK[1]).replace(SKY[2], SKY_DARK[2])
    sky_dark = svg(1024, '<rect width="1024" height="1024" fill="url(#sky)"></rect>', dark % "sky")
    wdefs, wbody = water("m")
    water_layer = svg(1024, '<g %s><g %s>\n%s\n</g></g>' % (MASTER, SHIFT, wbody), wdefs)
    bridge_layer = svg(1024, '<g %s><g %s>\n%s\n</g></g>' % (MASTER, SHIFT, bridge(1, DECK_LARGE, 22, CAPS_LARGE)))
    faders = svg(1024, '<g %s><g %s>\n%s\n</g></g>' % (MASTER, SHIFT, shaded_caps(CAPS_LARGE, CAP_LARGE, "face")), CAP_FACE % "face")
    composite = svg(1024, '<rect width="1024" height="1024" fill="url(#sky)"></rect>\n<g %s><g %s>\n%s\n%s\n%s\n</g></g>' % (
        MASTER, SHIFT, wbody, bridge(1, DECK_LARGE, 22, CAPS_LARGE), shaded_caps(CAPS_LARGE, CAP_LARGE, "face")),
        SKY_GRADIENT % "sky" + "\n" + CAP_FACE % "face" + "\n" + wdefs)
    return {"1-sky.svg": sky, "1-sky-dark.svg": sky_dark, "2-reflection.svg": water_layer, "3-bridge.svg": bridge_layer, "4-faders.svg": faders,
            "composite.svg": composite}


SHADOW = ('<filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">'
          '<feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000000" flood-opacity="0.3"></feDropShadow></filter>')


def legacy_large():
    wdefs, wbody = water("l")
    defs = "\n".join([SKY_GRADIENT % "sky", CAP_FACE % "face", wdefs, SHADOW,
                      '<clipPath id="body"><path d="%s"></path></clipPath>' % BODY])
    body = ('<path d="%s" fill="url(#sky)" filter="url(#shadow)"></path>\n<g clip-path="url(#body)"><g %s>\n%s\n%s\n%s\n</g></g>'
            % (BODY, SHIFT, wbody, bridge(1, DECK_LARGE, 22, CAPS_LARGE), shaded_caps(CAPS_LARGE, CAP_LARGE, "face")))
    return svg(1024, body, defs)


def legacy_medium():
    defs = "\n".join([SKY_GRADIENT % "sky", SHADOW, '<clipPath id="body"><path d="%s"></path></clipPath>' % BODY])
    body = ('<path d="%s" fill="url(#sky)" filter="url(#shadow)"></path>\n<g clip-path="url(#body)"><g transform="translate(0 40)">\n%s\n%s\n</g></g>'
            % (BODY, bridge(1.4, DECK_SMALL, 47.6, CAPS_MEDIUM), flat_caps(CAPS_MEDIUM, CAP_MEDIUM)))
    return svg(1024, body, defs)


def pixel_icon(n):
    """The 32 and 16 px icons, drawn on their own pixel grid so straight lines land on whole pixels."""
    if n == 32:
        body = (3, 3, 26, 26, 6)          # x, y, w, h, corner radius
        deck = (5, 20, 22, 2)             # x, y, w, h
        tower = (19, 7, 2, 13)
        top, anchors, low = (20, 8), (5, 27), 20
        caps = [(13, 17, 3, 2), (16, 14, 3, 2), (22, 17, 3, 2)]
        cable_w, hanger_w = 1.5, 1
    else:
        body = (2, 2, 12, 12, 3)
        deck = (3, 10, 10, 1)
        tower = (9, 4, 1, 6)
        top, anchors, low = (9.5, 4.5), (3, 13), 10
        caps = []  # no caps at 16 px: they read as dots (Adam, 2026-10-30)
        cable_w, hanger_w = 1, 0
    tx, ty = top
    parts = ['<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="url(#sky)"></rect>' % body]
    if hanger_w:
        for x, y, w, h in caps:
            cx = x + w / 2
            u = (cx - anchors[0]) / (tx - anchors[0]) if cx <= tx else (anchors[1] - cx) / (anchors[1] - tx)
            cy = low - (low - ty) * u * u
            parts.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%d" stroke="#4a6290" stroke-width="%d"></line>' % (cx, cy + 0.5, cx, deck[1], hanger_w))
    parts.append('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"></rect>' % (deck + (DECK_SMALL,)))
    parts.append('<g fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round">'
                 '<path d="M %.1f %.1f Q %.1f %d %d %d"></path><path d="M %.1f %.1f Q %.1f %d %d %d"></path></g>'
                 % (AMBER, cable_w, tx, ty, (tx + anchors[0]) / 2, low, anchors[0], low, tx, ty, (tx + anchors[1]) / 2, low, anchors[1], low))
    parts.append('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"></rect>' % (tower + (AMBER,)))
    parts += ['<rect x="%d" y="%d" width="%d" height="%d" fill="%s"></rect>' % (c + (CAP,)) for c in caps]
    return svg(n, "\n".join(parts), SKY_GRADIENT % "sky")


def menubar():
    """The menu-bar glyph (design D′, chosen by Adam, 2026-10-30): three faders under an arching
    cable, as a one-color template image, 20 x 18 points; macOS colors template images to suit the
    menu bar. The slots stop short of the arc so the two don't merge at actual size."""
    parts = ['<path d="M 1.5 8 Q 10 -2.5 18.5 8" fill="none" stroke="#000000" stroke-width="1.2" stroke-linecap="round"></path>']
    for x, top, cap in ((5.5, 7.0, 12.8), (10, 5.5, 9.8), (14.5, 7.0, 11.8)):
        parts.append('<line x1="%g" y1="%g" x2="%g" y2="16.5" stroke="#000000" stroke-width="0.8" stroke-linecap="round"></line>' % (x, top, x))
        parts.append('<rect x="%g" y="%g" width="3.2" height="2" rx="0.5"></rect>' % (x - 1.6, cap))
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="18" viewBox="0 0 20 18">\n<g fill="#000000">\n%s\n</g>\n</svg>\n'
            % "\n".join(parts))


def menubar_bridge():
    """The alternative glyph kept for later (design B): the icon's single-tower bridge, wide and
    low, with five hangers and piers in the water, 26 x 18 points."""
    deck, tx, top, a0, a1 = 12.5, 17, 2.2, 2, 24

    def cable(anchor):
        return '<path d="M %g %g Q %g %g %g %g" fill="none" stroke="#000000" stroke-width="1.1" stroke-linecap="round"></path>' % (
            tx, top, (anchor + tx) / 2, deck, anchor, deck)

    def hanger(x, anchor):
        u = (x - anchor) / (tx - anchor)
        return '<line x1="%g" y1="%.2f" x2="%g" y2="%g" stroke="#000000" stroke-width="0.7"></line>' % (x, deck - (deck - top) * u * u, x, deck)

    parts = ['<rect x="0.6" y="%g" width="24.8" height="1.5" rx="0.75"></rect>' % deck,
             '<rect x="%g" y="1.8" width="1.6" height="%g"></rect>' % (tx - 0.8, deck + 2.2),
             cable(a0), cable(a1)]
    parts += [hanger(x, a0) for x in (5.5, 8, 10.5, 13, 15.2)] + [hanger(x, a1) for x in (19, 21.3)]
    parts += ['<rect x="1.4" y="%g" width="1.2" height="3"></rect>' % (deck + 1.2),
              '<rect x="23.4" y="%g" width="1.2" height="3"></rect>' % (deck + 1.2)]
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="26" height="18" viewBox="0 0 26 18">\n<g fill="#000000">\n%s\n</g>\n</svg>\n'
            % "\n".join(parts))


def write(rel, text):
    path = os.path.join(HERE, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


if __name__ == "__main__":
    for name, text in master_layers().items():
        write("master/" + name, text)
    write("legacy/large.svg", legacy_large())
    write("legacy/medium.svg", legacy_medium())
    write("legacy/px32.svg", pixel_icon(32))
    write("legacy/px16.svg", pixel_icon(16))
    write("menubar/MenuBarIcon.svg", menubar())
    write("menubar/alternatives/MenuBarIcon-bridge.svg", menubar_bridge())
    print("Wrote master/, legacy/, and menubar/ in", HERE)

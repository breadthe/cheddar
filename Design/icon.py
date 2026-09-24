#!/usr/bin/env python3
"""Generates the Cheddar app icon SVGs (Design/AppIcon.svg and Design/AppIcon-small.svg).

The cheese is modelled as 3D boxes (a block and two slices) and projected in a three-quarter view.
Each visible face is shaded by how much it faces a top-left light; cut faces use the paste colours,
outer faces the rind colours. Edit the numbers below and re-run:

    python3 Design/icon.py
    sips -s format png Design/AppIcon.svg --out Design/AppIcon-1024.png
    sips -s format png Design/AppIcon-small.svg --out Design/AppIcon-small.png
    scripts/make-icons.sh
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))

# Projection: screen offset per 3D unit along x (block length), y (depth) and z (up).
EX = (0.9456, -0.325)
EY = (-0.906, -0.423)
EZ = (0.0, -1.0)
# Direction towards the viewer, and towards the light (top-left, a little in front).
VIEW = (-1.0, -1.0437, 0.7665)
LIGHT = (-0.75, -0.3, 0.6)

# Colours: (lit, shaded) for the cut paste and the rind.
PASTE = ((0xFF, 0xDA, 0x6E), (0xEE, 0x9C, 0x16))
RIND = ((0xFA, 0xBB, 0x30), (0xCC, 0x78, 0x0C))
EDGE = "#9A5406"

# The block, and the slices cut from its left (-x) end. Units are arbitrary; the art is fitted to the plate.
BLOCK = dict(size=(300, 170, 225))
SLICE_THICKNESS = 24


def norm(v):
    length = math.sqrt(sum(c * c for c in v))
    return tuple(c / length for c in v)


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


VIEW = norm(VIEW)
LIGHT = norm(LIGHT)


def project(p):
    x, y, z = p
    return (x * EX[0] + y * EY[0] + z * EZ[0], x * EX[1] + y * EY[1] + z * EZ[1])


def rot_y_tip(p, pivot_x, angle, lift=0.0):
    """Tips a point over towards -x, rotating in the xz-plane about the line x=pivot_x, z=0, then raises it."""
    x, y, z = p
    dx, s, c = x - pivot_x, math.sin(angle), math.cos(angle)
    return (pivot_x + dx * c - z * s, y, dx * s + z * c + lift)


def rot_z(p, center, angle):
    """Turns a point about a vertical axis through `center` (x, y)."""
    x, y, z = p
    dx, dy, s, c = x - center[0], y - center[1], math.sin(angle), math.cos(angle)
    return (center[0] + dx * c - dy * s, center[1] + dx * s + dy * c, z)


class Box:
    """An axis-aligned box in local space, placed in the scene by `transform`.

    Faces whose local normal is ±x are cut faces (paste); the rest are rind.
    """

    FACES = {  # local normal: corner indices (bit 0 = x, bit 1 = y, bit 2 = z), counter-clockwise from outside
        (-1, 0, 0): (0, 4, 6, 2), (1, 0, 0): (1, 3, 7, 5),
        (0, -1, 0): (0, 1, 5, 4), (0, 1, 0): (2, 6, 7, 3),
        (0, 0, -1): (0, 2, 3, 1), (0, 0, 1): (4, 5, 7, 6),
    }

    def __init__(self, origin, size, transform=lambda p: p, name=""):
        self.name = name
        ox, oy, oz = origin
        sx, sy, sz = size
        local = [(ox + sx * (i & 1), oy + sy * (i >> 1 & 1), oz + sz * (i >> 2 & 1)) for i in range(8)]
        self.corners = [transform(p) for p in local]
        centre = tuple(sum(c[k] for c in local) / 8 for k in range(3))
        self.faces = []
        for normal, idx in self.FACES.items():
            tip = transform(tuple(centre[k] + normal[k] for k in range(3)))
            world = norm(tuple(tip[k] - transform(centre)[k] for k in range(3)))
            self.faces.append((normal, world, [self.corners[i] for i in idx]))

    def centre(self):
        return tuple(sum(c[k] for c in self.corners) / 8 for k in range(3))


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def hexcolor(c):
    return "#%02X%02X%02X" % tuple(max(0, min(255, v)) for v in c)


def shade(world_normal, cut):
    lit, dark = PASTE if cut else RIND
    t = 1 - max(0.0, dot(world_normal, LIGHT))
    return mix(lit, dark, min(1.0, t * 1.15))


def scene(small):
    """Returns the boxes, back to front."""
    L, D, H = BLOCK["size"]
    s = SLICE_THICKNESS
    gap = 110
    boxes = [Box((0, 0, 0), (L, D, H), name="block")]
    if not small:
        # Falling, halfway over: separated from the cut end, tipped towards -x and just off the ground.
        pivot = -gap - s
        boxes.append(Box((pivot, 0, 0), (s, D, H), lambda p: rot_y_tip(p, pivot, math.radians(30), lift=18), "falling"))
    # Fallen flat, a little further out and turned slightly towards the viewer.
    pivot2 = -gap - s - (118 if not small else 20)
    turn = math.radians(-14)
    boxes.append(Box(
        (pivot2, 0, 0), (s, D, H),
        lambda p: rot_z(rot_y_tip(p, pivot2, math.radians(90)), (pivot2 - H / 2, D / 2 - 40), turn),
        "flat",
    ))
    # Painter's order: farthest from the viewer first.
    return sorted(boxes, key=lambda b: dot(b.centre(), VIEW))


def fit(points2d, box):
    xs, ys = [p[0] for p in points2d], [p[1] for p in points2d]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    bx, by, bw, bh = box
    k = min(bw / w, bh / h)
    ox = bx + (bw - w * k) / 2 - min(xs) * k
    oy = by + (bh - h * k) / 2 - min(ys) * k
    return lambda p: (ox + p[0] * k, oy + p[1] * k), k


def pts(points):
    return " ".join("%.1f,%.1f" % p for p in points)


def plate(small):
    top, bottom = ("#343436", "#070707")
    lines = ""
    if not small:
        # Faint horizontal rules, like Activity Monitor's graph paper (no vertical lines).
        rules = "".join('<line x1="100" x2="924" y1="%.1f" y2="%.1f"/>' % (y, y) for y in [100 + 824 * i / 9 for i in range(1, 9)])
        lines = '<g clip-path="url(#plateClip)" stroke="#FFFFFF" stroke-opacity="0.07" stroke-width="3">%s</g>' % rules
    return f'''  <defs>
    <linearGradient id="plateFill" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{top}"/>
      <stop offset="1" stop-color="{bottom}"/>
    </linearGradient>
    <clipPath id="plateClip"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
    <filter id="softShadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="16"/></filter>
    <filter id="contactShadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="5"/></filter>
  </defs>
  <!-- Plate: standard macOS icon grid (824x824 at 100,100) -->
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#plateFill)"/>
  {lines}
  <rect x="102" y="102" width="820" height="820" rx="183" fill="none" stroke="#FFFFFF" stroke-opacity="{0.10 if not small else 0.14}" stroke-width="4"/>
'''


def render(small):
    boxes = scene(small)
    to_screen, k = fit([project(c) for b in boxes for c in b.corners],
                       (140, 215, 744, 620) if not small else (150, 230, 724, 600))
    P = lambda p: to_screen(project(p))
    stroke = (3 if not small else 24)
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">',
           "  <!-- Generated by Design/icon.py. Edit that and re-run instead of editing this file. -->",
           plate(small)]

    # Shadows on the ground: each box's corners dropped to z=0, as a soft pool plus a tight contact line.
    out.append('  <g fill="#000000">')
    for b in boxes:
        ground = [P((c[0], c[1], 0)) for c in b.corners]
        hull = convex_hull(ground)
        out.append('    <polygon points="%s" opacity="0.55" filter="url(#softShadow)" transform="translate(6,14)"/>' % pts(hull))
        out.append('    <polygon points="%s" opacity="0.8" filter="url(#contactShadow)"/>' % pts(hull))
    out.append("  </g>")

    gradients, shapes = [], []
    for bi, b in enumerate(boxes):
        for fi, (local, world, corners) in enumerate(b.faces):
            if dot(world, VIEW) <= 0.02:
                continue
            cut = abs(local[0]) == 1
            base = shade(world, cut)
            poly = [P(c) for c in corners]
            gid = f"g{bi}_{fi}"
            # A soft sheen across each face: lighter towards the top-left, darker towards the bottom-right.
            a = min(poly, key=lambda p: p[0] + p[1])
            z = max(poly, key=lambda p: p[0] + p[1])
            gradients.append(
                f'    <linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{z[0]:.1f}" y2="{z[1]:.1f}">'
                f'<stop offset="0" stop-color="{hexcolor(mix(base, (255, 240, 200), 0.18))}"/>'
                f'<stop offset="1" stop-color="{hexcolor(mix(base, (150, 70, 0), 0.10))}"/></linearGradient>')
            shapes.append(f'    <polygon points="{pts(poly)}" fill="url(#{gid})"/>')
            if cut and not small and dot(world, VIEW) > 0.3:
                shapes.append(specks(b, local, corners, P))
        for local, world, corners in b.faces:
            if dot(world, VIEW) > 0.02:
                shapes.append(f'    <polygon points="{pts([P(c) for c in corners])}" fill="none" stroke="{EDGE}" '
                              f'stroke-width="{stroke}" stroke-linejoin="round" stroke-opacity="{0.55 if not small else 0.9}"/>')
    out.append("  <defs>\n" + "\n".join(gradients) + "\n  </defs>")
    out += shapes
    out.append("</svg>\n")
    return "\n".join(out)


def specks(box, local, corners, P):
    """Tiny pale crystals and a few darker pits on a cut face, placed in the face's own coordinates."""
    a, b, _, d = corners
    u = tuple(b[k] - a[k] for k in range(3))
    v = tuple(d[k] - a[k] for k in range(3))
    marks = [(0.22, 0.30, 3.2, "#FFF6D2", 0.8), (0.55, 0.22, 2.6, "#FFF6D2", 0.7), (0.38, 0.62, 3.0, "#FFF6D2", 0.75),
             (0.72, 0.55, 2.4, "#FFF6D2", 0.7), (0.62, 0.82, 2.8, "#FFF6D2", 0.6), (0.18, 0.78, 2.2, "#FFF6D2", 0.6),
             (0.46, 0.44, 2.4, "#B86E08", 0.35), (0.80, 0.30, 2.0, "#B86E08", 0.35), (0.30, 0.52, 1.8, "#B86E08", 0.3)]
    if box.name != "block":
        marks = marks[::3]
    out = []
    for s, t, r, colour, opacity in marks:
        p = P(tuple(a[k] + u[k] * s + v[k] * t for k in range(3)))
        out.append(f'<circle cx="{p[0]:.1f}" cy="{p[1]:.1f}" r="{r * 1.6:.1f}" fill="{colour}" opacity="{opacity}"/>')
    return "    " + "".join(out)


def convex_hull(points):
    pts_ = sorted(set(points))
    if len(pts_) <= 2:
        return pts_
    cross = lambda o, a, b: (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts_:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts_):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


if __name__ == "__main__":
    for name, small in (("AppIcon.svg", False), ("AppIcon-small.svg", True)):
        with open(os.path.join(HERE, name), "w") as f:
            f.write(render(small))
        print("wrote", name)

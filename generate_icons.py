#!/usr/bin/env python3
"""Generate ShiftingSands app icons (standard, dark, tinted) at 1024x1024.
Uses the exact hourglass profile from SandGeometry.swift via Catmull-Rom interpolation.
"""

from PIL import Image, ImageDraw, ImageFilter
import math
import random

random.seed(42)

SIZE = 1024
SUPER = 3  # supersampling factor for anti-aliasing
SS = SIZE * SUPER
CX, CY = SS // 2, SS // 2
SCALE = int(840 * SUPER)

# Hourglass profile control points from SandGeometry.swift (radius, height)
CONTROL_POINTS = [
    (0.00, -0.50), (0.16, -0.50), (0.22, -0.42), (0.22, -0.20),
    (0.15, -0.08), (0.04,  0.00), (0.15,  0.08), (0.22,  0.20),
    (0.22,  0.42), (0.16,  0.50), (0.00,  0.50),
]


# --- Catmull-Rom spline (matches SandGeometry.swift) ---

def catmull_rom(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    return 0.5 * ((2*p1) + (-p0+p2)*t + (2*p0-5*p1+4*p2-p3)*t2 + (-p0+3*p1-3*p2+p3)*t3)


def interpolate(points, subs=20):
    result = []
    n = len(points)
    for i in range(n - 1):
        p0 = points[max(i-1, 0)]
        p1 = points[i]
        p2 = points[min(i+1, n-1)]
        p3 = points[min(i+2, n-1)]
        steps = 1 if (i == 0 or i == n - 2) else subs
        for s in range(steps):
            t = s / steps
            r = catmull_rom(p0[0], p1[0], p2[0], p3[0], t)
            h = catmull_rom(p0[1], p1[1], p2[1], p3[1], t)
            result.append((max(r, 0), h))
    result.append(points[-1])
    return result


def radius_at(profile, y):
    """Interpolate glass inner radius at a given Y height."""
    for i in range(len(profile) - 1):
        r0, h0 = profile[i]
        r1, h1 = profile[i + 1]
        if h0 <= y <= h1:
            t = (y - h0) / (h1 - h0) if abs(h1 - h0) > 0.0001 else 0
            return r0 + t * (r1 - r0)
    return 0.0


# --- Coordinate helpers ---

def to_px(r, h):
    return (int(CX + r * SCALE), int(CY - h * SCALE))


def glass_outline_polygon(profile):
    """Full hourglass outline as a closed polygon (right side down, left side up)."""
    right = [to_px(r, h) for r, h in reversed(profile)]
    left = [to_px(-r, h) for r, h in profile]
    return right + left


def chamber_fill_polygon(profile, y_bot, y_top, inset=0.010):
    """Polygon filling the glass interior between two Y values."""
    steps = 100
    pts_r, pts_l = [], []
    for i in range(steps + 1):
        y = y_bot + (y_top - y_bot) * i / steps
        r = max(radius_at(profile, y) - inset, 0)
        pts_r.append(to_px(r, y))
        pts_l.append(to_px(-r, y))
    return list(reversed(pts_r)) + pts_l


# --- Drawing helpers ---

def draw_radial_glow(img, cx, cy, radius, center_rgb, bg_rgb):
    """Draw a soft radial glow on the image."""
    draw = ImageDraw.Draw(img)
    for step in range(radius, 0, -SUPER):
        t = step / radius
        # Ease out for softer falloff
        t = t * t
        c = tuple(int(center_rgb[j] + (bg_rgb[j] - center_rgb[j]) * t) for j in range(3))
        draw.ellipse((cx - step, cy - step, cx + step, cy + step), fill=c)


def draw_sand_particles(draw, profile, y_bot, y_top, count, colors, size_range):
    """Scatter decorative sand particle circles within a chamber region."""
    for _ in range(count):
        y = random.uniform(y_bot, y_top)
        max_r = radius_at(profile, y) - 0.018
        if max_r <= 0.005:
            continue
        x = random.uniform(-max_r, max_r)
        px, py = to_px(x, y)
        r = int(SCALE * random.uniform(*size_range))
        c = random.choice(colors)
        draw.ellipse((px - r, py - r, px + r, py + r), fill=c)


def draw_settled_particles(draw, profile, y_bot, y_top, sand, sand_hi, sand_dk):
    """Draw a neat settled pile of visible individual sand balls in the lower chamber."""
    ball_r_world = 0.022  # world-space radius per ball
    ball_r_px = int(SCALE * ball_r_world)
    spacing = ball_r_world * 2.05  # slight gap between balls

    # Pack rows from bottom up
    y = y_bot + ball_r_world
    while y < y_top:
        max_r = radius_at(profile, y) - 0.012
        if max_r < ball_r_world:
            y += spacing * 0.866  # hex row step
            continue
        # Determine if this is an odd row (offset for hex packing)
        row_idx = int(round((y - y_bot) / (spacing * 0.866)))
        offset = ball_r_world if row_idx % 2 else 0
        x = -max_r + ball_r_world + offset
        while x < max_r - ball_r_world + 0.001:
            px, py = to_px(x, y)
            # Base ball
            draw.ellipse((px - ball_r_px, py - ball_r_px,
                          px + ball_r_px, py + ball_r_px), fill=sand)
            # Highlight (upper-left)
            hr = max(1, ball_r_px // 3)
            hx, hy = px - ball_r_px // 3, py - ball_r_px // 3
            draw.ellipse((hx - hr, hy - hr, hx + hr, hy + hr), fill=sand_hi)
            # Shadow (lower-right)
            sr = max(1, ball_r_px // 4)
            sx, sy = px + ball_r_px // 4, py + ball_r_px // 4
            draw.ellipse((sx - sr, sy - sr, sx + sr, sy + sr), fill=sand_dk)
            x += spacing
        y += spacing * 0.866


def draw_glass_edges(draw, profile, color, width):
    """Draw the glass edge outline on both sides."""
    right = [to_px(r, h) for r, h in profile]
    left = [to_px(-r, h) for r, h in profile]
    for pts in [right, left]:
        for i in range(len(pts) - 1):
            draw.line([pts[i], pts[i + 1]], fill=color, width=width)


def draw_specular_highlight(draw, profile, base_color, width):
    """Draw a subtle specular highlight curve on the right side of the glass."""
    pts = []
    for r, h in profile:
        if -0.38 < h < 0.38 and r > 0.08:
            pts.append(to_px(r * 0.72, h))
    for i in range(len(pts) - 1):
        # Vary brightness based on vertical position (brightest at widest point)
        mid_y = (pts[i][1] + pts[i + 1][1]) / 2
        dist = abs(mid_y - CY) / (SCALE * 0.35)
        brightness = max(0, 1.0 - dist)
        c = tuple(min(255, base_color[j] + int(brightness * 50)) for j in range(3))
        draw.line([pts[i], pts[i + 1]], fill=c, width=width)


def draw_caps(draw, profile, cap_color, cap_highlight, cap_shadow):
    """Draw wooden cap bands at top and bottom of hourglass."""
    cap_h = int(SCALE * 0.026)
    cap_w = int(SCALE * 0.172)
    cap_r = cap_h // 3

    for y_val in [0.50, -0.50]:
        _, py = to_px(0, y_val)
        # Main cap body
        draw.rounded_rectangle(
            (CX - cap_w, py - cap_h, CX + cap_w, py + cap_h),
            radius=cap_r, fill=cap_color
        )
        # Highlight stripe
        draw.line(
            (CX - cap_w + cap_r, py - cap_h // 3,
             CX + cap_w - cap_r, py - cap_h // 3),
            fill=cap_highlight, width=max(2, cap_h // 3)
        )
        # Shadow stripe
        draw.line(
            (CX - cap_w + cap_r, py + cap_h // 3,
             CX + cap_w - cap_r, py + cap_h // 3),
            fill=cap_shadow, width=max(1, cap_h // 5)
        )


def draw_falling_particles(draw, sand_color, sand_highlight):
    """Draw a few individual sand particles falling through the neck."""
    particles = [
        (0.000, 0.15, 0.013),
        (0.018, 0.10, 0.011),
        (-0.012, 0.06, 0.012),
        (0.006, 0.02, 0.010),
        (-0.005, -0.03, 0.011),
        (0.010, -0.07, 0.012),
        (-0.015, 0.12, 0.010),
    ]
    for px_r, py_h, sz in particles:
        px, py = to_px(px_r, py_h)
        r = int(SCALE * sz)
        draw.ellipse((px - r, py - r, px + r, py + r), fill=sand_color)
        # Tiny highlight dot
        hr = max(1, r // 3)
        hx, hy = px - r // 4, py - r // 4
        draw.ellipse((hx - hr, hy - hr, hx + hr, hy + hr), fill=sand_highlight)


# --- Main icon generation ---

def generate_icon(bg, glass_fill, glass_edge, sand, sand_hi, sand_dk,
                  cap, cap_hi, cap_shadow, glow, output_path):
    profile = interpolate(CONTROL_POINTS)

    img = Image.new("RGB", (SS, SS), bg)

    # 1. Subtle ambient glow behind hourglass
    glow_radius = int(SCALE * 0.32)
    draw_radial_glow(img, CX, CY, glow_radius, glow, bg)

    draw = ImageDraw.Draw(img)

    # 2. Glass body fill (dark interior)
    glass_poly = glass_outline_polygon(profile)
    draw.polygon(glass_poly, fill=glass_fill)

    # 3. Sand — shallow layer at the very bottom, like the screenshot
    draw_settled_particles(draw, profile, -0.49, -0.34, sand, sand_hi, sand_dk)

    # 8. Wooden caps
    draw_caps(draw, profile, cap, cap_hi, cap_shadow)

    # 9. Glass edge outlines
    edge_w = max(2, int(SUPER * 2.0))
    draw_glass_edges(draw, profile, glass_edge, edge_w)

    # 10. Specular highlight on right side of glass
    spec_w = max(1, int(SUPER * 1.2))
    draw_specular_highlight(draw, profile, glass_edge, spec_w)

    # Downscale with high-quality resampling
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(output_path, "PNG")
    print(f"Saved: {output_path} ({img.size[0]}x{img.size[1]})")
    return img


# --- Generate all three variants ---

BASE = "/Users/pwilliams/appledev/ShiftingSands/ShiftingSands/Assets.xcassets/AppIcon.appiconset"

# Standard icon (warm dark background, vibrant)
generate_icon(
    bg=(38, 36, 58),             # warm dark purple-grey
    glass_fill=(48, 48, 72),     # subtle dark blue interior
    glass_edge=(150, 160, 190),  # bright blue-silver edge
    sand=(196, 154, 70),         # golden sand (matches app's 0.76/0.60/0.28 * 255)
    sand_hi=(225, 185, 105),     # highlight gold
    sand_dk=(155, 118, 48),      # shadow gold
    cap=(185, 155, 115),         # warm wood
    cap_hi=(215, 188, 148),      # wood highlight
    cap_shadow=(140, 112, 78),   # wood shadow
    glow=(55, 50, 75),           # subtle warm glow
    output_path=f"{BASE}/hourglass_icon.png",
)

# Dark icon (deep charcoal, cooler tones, more contrast)
generate_icon(
    bg=(26, 26, 46),             # #1A1A2E deep charcoal
    glass_fill=(36, 38, 56),     # darker interior
    glass_edge=(130, 140, 175),  # slightly dimmer edge
    sand=(196, 154, 70),         # same golden sand
    sand_hi=(225, 185, 105),     # highlight gold
    sand_dk=(155, 118, 48),      # shadow gold
    cap=(175, 145, 108),         # slightly cooler wood
    cap_hi=(205, 178, 138),      # wood highlight
    cap_shadow=(130, 105, 72),   # wood shadow
    glow=(42, 40, 62),           # subtler glow
    output_path=f"{BASE}/hourglass_icon_dark.png",
)

# Tinted icon (greyscale)
generate_icon(
    bg=(28, 28, 28),             # near-black
    glass_fill=(42, 42, 42),     # dark grey interior
    glass_edge=(140, 140, 140),  # grey edge
    sand=(160, 160, 160),        # light grey (sand)
    sand_hi=(190, 190, 190),     # highlight
    sand_dk=(125, 125, 125),     # shadow
    cap=(150, 150, 150),         # mid grey cap
    cap_hi=(175, 175, 175),      # cap highlight
    cap_shadow=(115, 115, 115),  # cap shadow
    glow=(40, 40, 40),           # subtle glow
    output_path=f"{BASE}/hourglass_icon_tinted.png",
)

print("All icons generated!")

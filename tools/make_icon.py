#!/usr/bin/env python3
"""Generate the Comic Viewer app icon into Sources/Assets.xcassets/AppIcon.appiconset.
A rounded indigo tile with a white comic page (panel lines) and a red bookmark ribbon
(nodding to chapters). Re-run to regenerate. Replace with real art anytime."""
import json, os, math
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Sources", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)
S = 1024
SS = 2  # supersample


def rounded(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r, fill=fill)


def vgradient(size, top, bot):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        g.putpixel((0, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def render(px):
    s = px * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # rounded tile
    m = int(s * 0.055)
    r = int(s * 0.225)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, s - m, s - m], radius=r, fill=255)
    bg = vgradient((s, s), (86, 96, 214), (44, 50, 120)).convert("RGBA")
    img.paste(bg, (0, 0), mask)

    # white page (slightly tall), centered
    pw, ph = int(s * 0.46), int(s * 0.56)
    px0, py0 = (s - pw) // 2, (s - ph) // 2
    pr = int(s * 0.03)
    # soft shadow
    sh = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        [px0 + int(s * 0.012), py0 + int(s * 0.02), px0 + pw + int(s * 0.012),
         py0 + ph + int(s * 0.02)], radius=pr, fill=(0, 0, 0, 90))
    img.alpha_composite(sh)
    d.rounded_rectangle([px0, py0, px0 + pw, py0 + ph], radius=pr, fill=(245, 246, 250, 255))

    # comic panel lines
    line = (150, 156, 176, 255)
    lw = max(2, int(s * 0.006))
    y1 = py0 + int(ph * 0.42)
    y2 = py0 + int(ph * 0.70)
    d.line([px0 + int(pw * 0.08), y1, px0 + pw - int(pw * 0.08), y1], fill=line, width=lw)
    d.line([px0 + int(pw * 0.08), y2, px0 + pw - int(pw * 0.08), y2], fill=line, width=lw)
    xm = px0 + pw // 2
    d.line([xm, y1, xm, py0 + ph - int(ph * 0.06)], fill=line, width=lw)

    # red bookmark ribbon near the top-right of the page
    bw = int(pw * 0.18)
    bx = px0 + int(pw * 0.62)
    by = py0 - int(s * 0.01)
    bh = int(ph * 0.34)
    d.rectangle([bx, by, bx + bw, by + bh], fill=(226, 54, 54, 255))
    # notch
    d.polygon([(bx, by + bh), (bx + bw // 2, by + bh - int(bw * 0.5)),
               (bx + bw, by + bh)], fill=(0, 0, 0, 0))
    # re-fill notch with transparency by cutting: draw triangle in bg? simplest: overpaint page color
    d.polygon([(bx, by + bh), (bx + bw // 2, by + bh - int(bw * 0.55)),
               (bx + bw, by + bh)], fill=(245, 246, 250, 255))

    return img.resize((px, px), Image.LANCZOS)


sizes = [16, 32, 64, 128, 256, 512, 1024]
for px in sizes:
    render(px).save(os.path.join(OUT, f"icon_{px}.png"))

contents = {"images": [], "info": {"version": 1, "author": "xcode"}}
mac = [(16, 1, 16), (16, 2, 32), (32, 1, 32), (32, 2, 64), (128, 1, 128),
       (128, 2, 256), (256, 1, 256), (256, 2, 512), (512, 1, 512), (512, 2, 1024)]
for pt, scale, px in mac:
    contents["images"].append({
        "idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x",
        "filename": f"icon_{px}.png"})
with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump(contents, f, indent=2)

# asset catalog root
root = os.path.join(HERE, "..", "Sources", "Assets.xcassets")
with open(os.path.join(root, "Contents.json"), "w") as f:
    json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)

print("wrote icons to", os.path.relpath(OUT))

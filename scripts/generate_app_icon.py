#!/usr/bin/env python3
"""Generate the JARVIS app icon and repository artwork.

Everything here is produced from geometry defined in this file: no third-party
imagery, no trademarked characters, and no downloaded assets. Re-run after
editing the palette or the orb constants to restyle the whole set.

Outputs
  assets/app-icon/icon-1024.png          iOS marketing icon (opaque, 1024²)
  assets/app-icon/icon-180.png           home-screen preview
  assets/backgrounds/hero-1200x630.png   repository / documentation hero image
  ios/JarvisApp/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png

Authoring-time dependencies: Pillow, numpy. The iOS app itself depends on
neither.
"""

from __future__ import annotations

import argparse
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ----------------------------------------------------------------- palette ---
INK = (0.043, 0.047, 0.055)          # near-black, matches JarvisTheme.Palette.ink
GRAPHITE = (0.078, 0.086, 0.098)
SLATE = (0.129, 0.141, 0.161)
DEEP = (0.075, 0.196, 0.318)         # deep blue, sphere shadow
ICE = (0.545, 0.780, 0.980)
CYAN = (0.290, 0.898, 0.925)
SILVER = (0.839, 0.863, 0.894)

SEED = 20261016


def rgb(values, alpha: float = 1.0) -> tuple[int, int, int, int]:
    return tuple(int(round(255 * channel)) for channel in values) + (int(round(255 * alpha)),)


# -------------------------------------------------------------- background ---
def background(size: int) -> Image.Image:
    """Graphite plane with an off-centre light source, a vignette and fine grain."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / (size - 1)
    diagonal = np.clip(x * 0.35 + y * 0.65, 0, 1)
    base = np.zeros((size, size, 3), dtype=np.float32)
    for index, (dark, light) in enumerate(zip(GRAPHITE, SLATE)):
        base[..., index] = dark + (light - dark) * diagonal

    radial = np.sqrt((x - 0.42) ** 2 + (y - 0.24) ** 2) / 0.9
    sheen = np.clip(1 - radial, 0, 1) ** 2.4
    for index, channel in enumerate(ICE):
        base[..., index] += channel * 0.09 * sheen

    vignette = 1 - 0.45 * np.clip((np.maximum(np.abs(x - 0.5), np.abs(y - 0.5)) - 0.28) / 0.5, 0, 1) ** 1.6
    base *= vignette[..., None]

    rng = np.random.default_rng(SEED)
    base += rng.normal(0, 0.0032, (size, size, 1))
    return Image.fromarray((np.clip(base, 0, 1) * 255).astype(np.uint8), "RGB")


# ------------------------------------------------------------- layer helpers -
def blur_alpha(layer: Image.Image, radius: float) -> Image.Image:
    """Blur only the alpha channel.

    Blurring an RGBA image directly drags the RGB channels toward the transparent
    black surround, which leaves a grey halo around white shapes (the rings that
    appeared in earlier revisions of this artwork). Antialiasing alpha alone keeps
    the colours exact.
    """
    red, green, blue, alpha = layer.split()
    return Image.merge("RGBA", (red, green, blue, alpha.filter(ImageFilter.GaussianBlur(radius))))


def scale_alpha(layer: Image.Image, factor: float) -> Image.Image:
    array = np.asarray(layer).astype(np.float32)
    array[..., 3] *= factor
    return Image.fromarray(np.clip(array, 0, 255).astype(np.uint8), "RGBA")


def erase_inside(layer: Image.Image, centre: tuple[float, float], radius: float) -> Image.Image:
    """Clear a disc so orbital rings read as passing behind the glass sphere."""
    size = layer.size[0]
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    mask = np.sqrt((xs - centre[0]) ** 2 + (ys - centre[1]) ** 2) <= radius
    array = np.asarray(layer).astype(np.float32).copy()
    array[mask, 3] = 0
    return Image.fromarray(np.clip(array, 0, 255).astype(np.uint8), "RGBA")


# ---------------------------------------------------------------------- orb ---
def draw_orb(canvas: Image.Image, centre: tuple[float, float], radius: float,
             glow_scale: float = 1.55, ring: bool = True, lattice: bool = True) -> None:
    """A glass sphere rendered from a unit-sphere model.

    Stages: outer glow → lambert-lit body → inner bloom → caustic → analytic
    specular → shaded limb → crisp glass edge → faint orbital hardware.
    """
    size = canvas.size[0]
    cx, cy = centre
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    dx = (xs - cx) / radius
    dy = (ys - cy) / radius
    distance = np.sqrt(dx ** 2 + dy ** 2)
    inside = np.clip(1 - distance, 0, 1)

    # Outer glow: cyan bleeding into deep blue, fading out.
    falloff = np.clip(1 - distance / glow_scale, 0, 1) ** 2.6
    glow = np.zeros((size, size, 4), dtype=np.float32)
    for index, (near, far) in enumerate(zip(CYAN, DEEP)):
        glow[..., index] = (near * falloff + far * (1 - falloff)) * 255
    glow[..., 3] = falloff * 88
    canvas.alpha_composite(Image.fromarray(glow.astype(np.uint8), "RGBA"))

    # Body: lambert shading of a sphere lit from the upper left.
    normal_z = np.sqrt(np.clip(1 - np.clip(distance, 0, 1) ** 2, 0, 1))
    lambert = np.clip(dx * -0.52 + dy * -0.60 + normal_z * 0.61, 0, 1)
    vertical = np.clip(0.5 - dy * 0.5, 0, 1)

    body_rgb = np.array(DEEP) * (1 - vertical[..., None]) + (np.array(ICE) * 0.94 + 0.06) * vertical[..., None]
    body_rgb *= 0.74
    body_rgb += np.array(ICE) * (lambert[..., None] ** 3.0) * 0.55
    body_rgb += (lambert[..., None] ** 1.4) * np.clip(lambert - 0.74, 0, 1)[..., None] * 0.42
    body_rgb += np.array(CYAN) * (inside[..., None] ** 3) * 0.05

    fresnel = np.clip(distance, 0, 1) ** 7
    lit_side = np.clip(0.35 - dx * 0.55 - dy * 0.55, 0, 1)
    body_rgb += np.array([0.80, 0.90, 1.0]) * (fresnel * (0.28 + 0.90 * lit_side))[..., None]

    body = np.zeros((size, size, 4), dtype=np.float32)
    body[..., :3] = np.clip(body_rgb, 0, 1) * 255
    body[..., 3] = np.where(distance <= 1.0, 255, 0)
    canvas.alpha_composite(Image.fromarray(body.astype(np.uint8), "RGBA"))

    # Caustic: refracted light pooling toward the lower right.
    caustic = np.clip(1 - np.sqrt((dx - 0.34) ** 2 + (dy - 0.46) ** 2) / 0.85, 0, 1) ** 2.0
    caustic *= np.clip(distance, 0, 1) ** 2.2
    layer = np.zeros((size, size, 4), dtype=np.float32)
    layer[..., 0], layer[..., 1], layer[..., 2] = (channel * 255 for channel in CYAN)
    layer[..., 3] = caustic * 110
    canvas.alpha_composite(Image.fromarray(layer.astype(np.uint8), "RGBA"))

    # Inner bloom just under the lit shoulder.
    bloom = np.clip(1 - np.sqrt((dx + 0.18) ** 2 + (dy + 0.12) ** 2) / 0.85, 0, 1) ** 2.6
    bloom *= inside ** 0.35
    layer = np.zeros((size, size, 4), dtype=np.float32)
    layer[..., 0], layer[..., 1], layer[..., 2] = 219, 242, 255
    layer[..., 3] = bloom * 92
    canvas.alpha_composite(Image.fromarray(layer.astype(np.uint8), "RGBA"))

    # Specular: analytic gaussians (no blurred primitives, so no rings).
    sx, sy = dx + 0.34, dy + 0.40
    broad = np.exp(-((sx / 0.42) ** 2 + (sy / 0.26) ** 2))
    tight = np.exp(-((sx / 0.15) ** 2 + (sy / 0.10) ** 2))
    specular = np.clip(broad * 0.5 + tight * 0.8, 0, 1) * inside ** 0.6
    layer = np.zeros((size, size, 4), dtype=np.float32)
    layer[..., :3] = 255
    layer[..., 3] = specular * 118
    canvas.alpha_composite(Image.fromarray(layer.astype(np.uint8), "RGBA"))

    # Shaded limb: keeps the sphere from reading flat at small sizes.
    limb = np.clip((distance - 0.72) / 0.28, 0, 1) ** 2 * np.clip(0.45 - dx * 0.5 - dy * 0.5, 0, 1)
    layer = np.zeros((size, size, 4), dtype=np.float32)
    layer[..., 2] = 40
    layer[..., 3] = limb * 66
    canvas.alpha_composite(Image.fromarray(layer.astype(np.uint8), "RGBA"))

    # Crisp glass edge.
    edge = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(edge, "RGBA").ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        outline=(226, 238, 252, 255), width=max(2, int(round(radius * 0.016))))
    canvas.alpha_composite(scale_alpha(blur_alpha(edge, radius * 0.004), 0.90))

    # Orbital hardware — deliberately faint, and always behind the glass.
    if ring:
        rings = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        rr = radius * 1.26
        ImageDraw.Draw(rings, "RGBA").ellipse(
            [cx - rr, cy - rr * 0.99, cx + rr, cy + rr * 0.99],
            outline=rgb(SILVER, 0.9), width=max(1, int(round(radius * 0.007))))
        rings = erase_inside(blur_alpha(rings, radius * 0.004), centre, radius * 1.02)
        canvas.alpha_composite(scale_alpha(rings, 0.28))

    if lattice:
        arcs = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        drawer = ImageDraw.Draw(arcs, "RGBA")
        for scale, start, end, width in [(1.55, 186, 354, 0.009), (1.72, 198, 342, 0.006)]:
            rr = radius * scale
            drawer.arc([cx - rr, cy - rr * 0.34, cx + rr, cy + rr * 0.34], start=start, end=end,
                       fill=rgb((0.63, 0.86, 0.94), 0.9), width=max(1, int(round(radius * width))))
        arcs = erase_inside(blur_alpha(arcs, radius * 0.006), centre, radius * 1.30)
        canvas.alpha_composite(scale_alpha(arcs, 0.28))


def compose(size: int, orb_scale: float = 0.58) -> Image.Image:
    canvas = background(size).convert("RGBA")
    draw_orb(canvas, (size * 0.5, size * 0.505), size * orb_scale * 0.5)
    return canvas


# ------------------------------------------------------------------ writers ---
def write_icon(path: pathlib.Path, size: int) -> None:
    image = compose(size)
    flat = Image.new("RGB", (size, size), tuple(int(255 * c) for c in GRAPHITE))
    flat.paste(image.convert("RGB"), (0, 0), image.split()[3])
    path.parent.mkdir(parents=True, exist_ok=True)
    flat.save(path, "PNG", optimize=True)
    print(f"wrote {path} ({size}x{size})")


def write_hero(path: pathlib.Path, width: int = 1200, height: int = 630) -> None:
    canvas = Image.new("RGB", (width, height), tuple(int(255 * c) for c in INK))
    panel = compose(height).convert("RGB").resize((height, height))
    canvas.paste(panel, (width - height, 0))

    # Fade the artwork into the panel so the left half stays calm.
    gradient = Image.new("L", (width, 1))
    edge = width - height
    for x in range(width):
        if x < edge - 280:
            gradient.putpixel((x, 0), 255)
        elif x < edge + 140:
            gradient.putpixel((x, 0), int(255 * (1 - (x - (edge - 280)) / 420)))
        else:
            gradient.putpixel((x, 0), 0)
    canvas.paste(Image.new("RGB", (width, height), tuple(int(255 * c) for c in INK)),
                 (0, 0), gradient.resize((width, height)))

    # Wordmark, if a system font is available (authoring-time only).
    try:
        from PIL import ImageFont
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 96)
        small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 30)
        drawer = ImageDraw.Draw(canvas)
        drawer.text((86, 232), "J A R V I S", font=font, fill=rgb(SILVER))
        drawer.text((88, 356), "on-device memory · free-tier AI · official APIs only",
                    font=small, fill=rgb((0.62, 0.72, 0.82)))
    except OSError:
        pass

    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(path, "PNG", optimize=True)
    print(f"wrote {path} ({width}x{height})")


def write_lockup(path: pathlib.Path, size: int = 512) -> None:
    """Square artwork without the icon mask — used in documentation headers."""
    compose(size).save(path, "PNG", optimize=True)
    print(f"wrote {path} ({size}x{size})")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate JARVIS artwork")
    parser.add_argument("--repo-root", default=str(pathlib.Path(__file__).resolve().parents[1]))
    args = parser.parse_args()
    root = pathlib.Path(args.repo_root)

    write_icon(root / "assets/app-icon/icon-1024.png", 1024)
    write_icon(root / "assets/app-icon/icon-180.png", 180)
    write_icon(root / "ios/JarvisApp/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png", 1024)
    write_hero(root / "assets/backgrounds/hero-1200x630.png")
    write_lockup(root / "assets/illustrations/orb-lockup-512.png", 512)


if __name__ == "__main__":
    main()

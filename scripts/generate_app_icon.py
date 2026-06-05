#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ICONSET_SPECS = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def lerp(start: int, end: int, t: float) -> int:
    return round(start + (end - start) * t)


def gradient_background(size: int) -> Image.Image:
    top = (9, 19, 31)
    middle = (13, 67, 76)
    bottom = (16, 24, 39)
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        if t < 0.58:
            local = t / 0.58
            color = tuple(lerp(top[i], middle[i], local) for i in range(3))
        else:
            local = (t - 0.58) / 0.42
            color = tuple(lerp(middle[i], bottom[i], local) for i in range(3))
        for x in range(size):
            vignette = 1.0 - 0.22 * math.hypot((x / size) - 0.5, (y / size) - 0.5)
            pixels[x, y] = tuple(max(0, min(255, round(channel * vignette))) for channel in color) + (255,)
    return image


def polygon(cx: float, cy: float, radius: float, sides: int, rotation: float) -> list[tuple[float, float]]:
    return [
        (
            cx + math.cos(rotation + (math.tau * i / sides)) * radius,
            cy + math.sin(rotation + (math.tau * i / sides)) * radius,
        )
        for i in range(sides)
    ]


def rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    inset = round(size * 0.035)
    draw.rounded_rectangle(
        [inset, inset, size - inset, size - inset],
        radius=round(size * 0.22),
        fill=255,
    )
    return mask


def draw_icon(size: int = 1024) -> Image.Image:
    scale = size / 1024
    image = gradient_background(size)
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Subtle geometric field.
    grid_color = (125, 232, 227, 30)
    for offset in range(-1024, 2048, 128):
        draw.line(
            [(offset * scale, 0), ((offset + 760) * scale, size)],
            fill=grid_color,
            width=max(1, round(2 * scale)),
        )
        draw.line(
            [((1024 - offset) * scale, 0), ((264 - offset) * scale, size)],
            fill=(68, 137, 255, 22),
            width=max(1, round(2 * scale)),
        )

    center = (512 * scale, 500 * scale)
    halo = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    halo_draw = ImageDraw.Draw(halo)
    halo_draw.ellipse(
        [
            center[0] - 310 * scale,
            center[1] - 310 * scale,
            center[0] + 310 * scale,
            center[1] + 310 * scale,
        ],
        fill=(36, 210, 205, 44),
    )
    halo = halo.filter(ImageFilter.GaussianBlur(radius=34 * scale))
    image = Image.alpha_composite(image, halo)

    diamond_shadow = polygon(center[0] + 10 * scale, center[1] + 18 * scale, 270 * scale, 4, math.pi / 4)
    draw.polygon(diamond_shadow, fill=(0, 0, 0, 92))
    diamond = polygon(center[0], center[1], 270 * scale, 4, math.pi / 4)
    draw.polygon(diamond, fill=(12, 31, 47, 236), outline=(137, 245, 237, 190))

    inner = polygon(center[0], center[1], 184 * scale, 4, math.pi / 4)
    draw.polygon(inner, fill=(16, 90, 105, 238), outline=(91, 188, 255, 210))

    route = [
        (352 * scale, 540 * scale),
        (430 * scale, 438 * scale),
        (522 * scale, 563 * scale),
        (672 * scale, 366 * scale),
    ]
    draw.line(route, fill=(224, 253, 252, 232), width=max(4, round(22 * scale)), joint="curve")
    draw.line(route, fill=(74, 222, 216, 255), width=max(2, round(9 * scale)), joint="curve")

    draw.ellipse(
        [
            center[0] - 92 * scale,
            center[1] - 92 * scale,
            center[0] + 92 * scale,
            center[1] + 92 * scale,
        ],
        outline=(236, 254, 255, 245),
        width=max(3, round(16 * scale)),
    )
    draw.ellipse(
        [
            center[0] - 34 * scale,
            center[1] - 34 * scale,
            center[0] + 34 * scale,
            center[1] + 34 * scale,
        ],
        fill=(236, 254, 255, 255),
    )

    pin_tip = [
        (center[0], 802 * scale),
        (442 * scale, 620 * scale),
        (582 * scale, 620 * scale),
    ]
    draw.polygon(pin_tip, fill=(74, 222, 216, 248))
    draw.line(
        [(center[0], 642 * scale), (center[0], 802 * scale)],
        fill=(236, 254, 255, 190),
        width=max(2, round(7 * scale)),
    )

    image = Image.alpha_composite(image, overlay)
    image.putalpha(rounded_mask(size))
    return image


def write_iconset(iconset: Path, preview: Path | None) -> None:
    iconset.mkdir(parents=True, exist_ok=True)
    master = draw_icon(1024)
    for filename, size in ICONSET_SPECS:
        resized = master.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(iconset / filename)
    if preview is not None:
        preview.parent.mkdir(parents=True, exist_ok=True)
        master.save(preview)


def generate_icns(output: Path, preview: Path | None, keep_iconset: Path | None) -> None:
    iconutil = shutil.which("iconutil")
    if iconutil is None:
        raise SystemExit("iconutil was not found")

    with tempfile.TemporaryDirectory(prefix="LocateAppIcon-") as temp:
        iconset = keep_iconset or Path(temp) / "AppIcon.iconset"
        write_iconset(iconset, preview)
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([iconutil, "-c", "icns", "-o", str(output), str(iconset)], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate LocateApp macOS app icon assets.")
    parser.add_argument("--output", required=True, type=Path, help="Destination .icns path")
    parser.add_argument("--preview", type=Path, help="Optional 1024px PNG preview path")
    parser.add_argument("--iconset", type=Path, help="Optional iconset directory to keep")
    args = parser.parse_args()

    generate_icns(args.output, args.preview, args.iconset)


if __name__ == "__main__":
    main()

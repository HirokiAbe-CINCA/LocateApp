#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw


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
    top = (9, 18, 28)
    middle = (10, 44, 53)
    bottom = (8, 14, 24)
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
            vignette = 1.0 - 0.16 * math.hypot((x / size) - 0.5, (y / size) - 0.5)
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

    center = (512 * scale, 498 * scale)
    shadow = polygon(center[0] + 12 * scale, center[1] + 22 * scale, 286 * scale, 4, 0)
    draw.polygon(shadow, fill=(0, 0, 0, 86))

    outer = polygon(center[0], center[1], 288 * scale, 4, 0)
    inner = polygon(center[0], center[1], 190 * scale, 4, 0)
    draw.polygon(outer, fill=(79, 232, 224, 255))
    draw.polygon(inner, fill=(9, 30, 42, 255))

    draw.ellipse(
        [
            center[0] - 78 * scale,
            center[1] - 78 * scale,
            center[0] + 78 * scale,
            center[1] + 78 * scale,
        ],
        outline=(238, 255, 254, 255),
        width=max(4, round(18 * scale)),
    )
    draw.ellipse(
        [
            center[0] - 24 * scale,
            center[1] - 24 * scale,
            center[0] + 24 * scale,
            center[1] + 24 * scale,
        ],
        fill=(238, 255, 254, 255),
    )

    stem_width = 28 * scale
    draw.rounded_rectangle(
        [
            center[0] - stem_width / 2,
            center[1] + 92 * scale,
            center[0] + stem_width / 2,
            center[1] + 278 * scale,
        ],
        radius=round(14 * scale),
        fill=(79, 232, 224, 255),
    )
    draw.polygon(
        [
            (center[0], 804 * scale),
            (center[0] - 58 * scale, 704 * scale),
            (center[0] + 58 * scale, 704 * scale),
        ],
        fill=(238, 255, 254, 255),
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

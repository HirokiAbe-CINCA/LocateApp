#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH = 920
HEIGHT = 420


def lerp(start: int, end: int, t: float) -> int:
    return round(start + (end - start) * t)


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc" if bold else "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for candidate in candidates:
        path = Path(candidate)
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def polygon(cx: float, cy: float, radius: float, sides: int, rotation: float) -> list[tuple[float, float]]:
    return [
        (
            cx + math.cos(rotation + (math.tau * i / sides)) * radius,
            cy + math.sin(rotation + (math.tau * i / sides)) * radius,
        )
        for i in range(sides)
    ]


def draw_background() -> Image.Image:
    image = Image.new("RGBA", (WIDTH, HEIGHT), (8, 14, 22, 255))
    pixels = image.load()
    top = (9, 18, 28)
    middle = (10, 54, 58)
    bottom = (7, 12, 21)
    for y in range(HEIGHT):
        t = y / max(HEIGHT - 1, 1)
        if t < 0.56:
            local = t / 0.56
            color = tuple(lerp(top[i], middle[i], local) for i in range(3))
        else:
            local = (t - 0.56) / 0.44
            color = tuple(lerp(middle[i], bottom[i], local) for i in range(3))
        for x in range(WIDTH):
            dx = (x / WIDTH) - 0.5
            dy = (y / HEIGHT) - 0.5
            vignette = 1.0 - 0.28 * math.hypot(dx, dy)
            pixels[x, y] = tuple(max(0, min(255, round(channel * vignette))) for channel in color) + (255,)

    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    center = (WIDTH / 2, 132)
    draw.polygon(polygon(center[0] + 4, center[1] + 8, 58, 4, 0), fill=(0, 0, 0, 70))
    draw.polygon(polygon(center[0], center[1], 60, 4, 0), fill=(79, 232, 224, 230))
    draw.polygon(polygon(center[0], center[1], 40, 4, 0), fill=(8, 28, 38, 245))
    draw.ellipse([center[0] - 15, center[1] - 15, center[0] + 15, center[1] + 15], fill=(238, 255, 254, 245))

    title_font = load_font(24, bold=True)
    label_font = load_font(14)
    title = "LocateApp"
    subtitle = "アプリをApplicationsへドラッグ"
    title_box = draw.textbbox((0, 0), title, font=title_font)
    subtitle_box = draw.textbbox((0, 0), subtitle, font=label_font)
    draw.text(((WIDTH - (title_box[2] - title_box[0])) / 2, 200), title, font=title_font, fill=(238, 255, 254, 255))
    draw.text(((WIDTH - (subtitle_box[2] - subtitle_box[0])) / 2, 234), subtitle, font=label_font, fill=(174, 220, 222, 245))

    draw.line([(346, 306), (574, 306)], fill=(79, 232, 224, 150), width=3)
    draw.polygon([(574, 306), (558, 296), (558, 316)], fill=(79, 232, 224, 180))

    return Image.alpha_composite(image, overlay)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate the LocateApp DMG background.")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    draw_background().save(args.output)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Turn a sheet of character expressions into a local AI Monitor character pack.

A sheet is a grid of square illustrations separated by white gutters (the
usual shape of a sticker/expression sheet). Each cell becomes:

  portrait-NN.png  the cell with its edges feathered into transparency, so the
                   character stands in the night-coloured hero card instead of
                   in a pasted square; used wherever the mascot is large.
  avatar-NN.png    a round crop of the face; used wherever the mascot is small
                   (section headers, empty notes, the footer), where a whole
                   cell would read as noise.

With --cutout (for a light theme, where a cell's dark ground would sit on the
page as a dark square) each cell is instead lifted off its ground with
Vision's subject mask (scripts/lift-subject.swift, run locally) and becomes:

  sticker-NN.png        the character on transparency with a white die-cut
                        edge and a soft shadow, like a sticker; for the mascot
  sticker-small-NN.png  the same at 200px, for small places
  avatar-NN.png         a round crop of the face on a pale disc

plus skin.json, which names the pack, says which theme it plays in (--skin)
and which cell plays which mascot mood (see MascotState.Mood). The app loads
packs from

    ~/Library/Application Support/AIMonitor/Skins/<name>/

**Character art never goes into this repository.** Illustrations of a
character someone else owns are fine on your own machine and are not ours to
publish in a public repo, so this script refuses to write inside a git working
tree, and the app only ever reads packs from the per-user directory above.

Usage:
    python3 scripts/make-character-skin.py SHEET.png --name evernight \
        --title "长夜月" --map moods.json
    python3 scripts/make-character-skin.py SHEET.png --name day \
        --title "…" --map moods.json --skin aubade --cutout
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import numpy as np
    from PIL import Image, ImageFilter
except ImportError:  # pragma: no cover - environment guidance only
    sys.exit("Needs Pillow and numpy: python3 -m pip install pillow numpy")

PORTRAIT_SIDE = 480   # 2x the largest place a mascot is drawn
AVATAR_SIDE = 200


def gutters(profile: np.ndarray, threshold: float = 0.97) -> list[tuple[int, int]]:
    """Runs of (almost) entirely white rows or columns."""
    runs, start = [], None
    for i, value in enumerate(profile):
        if value >= threshold and start is None:
            start = i
        elif value < threshold and start is not None:
            runs.append((start, i))
            start = None
    if start is not None:
        runs.append((start, len(profile)))
    return runs


def cells(sheet: Image.Image) -> list[Image.Image]:
    """Cells in reading order, found from the white gutters between them."""
    rgb = np.asarray(sheet.convert("RGB")).astype(int)
    white = rgb.min(axis=2) > 235
    cols = gutters(white.mean(axis=0))
    rows = gutters(white.mean(axis=1))

    def spans(runs: list[tuple[int, int]], length: int) -> list[tuple[int, int]]:
        edges = [0] + [p for run in runs for p in run] + [length]
        pairs = [(edges[i], edges[i + 1]) for i in range(0, len(edges), 2)]
        return [(a, b) for a, b in pairs if b - a > 32]

    xs = spans(cols, rgb.shape[1])
    ys = spans(rows, rgb.shape[0])
    if not xs or not ys:
        sys.exit("No grid found: expected cells separated by white gutters.")
    return [sheet.crop((x0, y0, x1, y1)) for y0, y1 in ys for x0, x1 in xs]


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def portrait(cell: Image.Image) -> Image.Image:
    """Feathered portrait: opaque in the middle, dissolving at the edges."""
    img = cell.convert("RGBA").resize((PORTRAIT_SIDE, PORTRAIT_SIDE), Image.LANCZOS)
    # A light unsharp mask restores the edge the downscale softens.
    img = img.filter(ImageFilter.UnsharpMask(radius=1.2, percent=45, threshold=2))
    h = w = PORTRAIT_SIDE
    y, x = np.mgrid[0:h, 0:w]
    # Slightly above centre: the faces sit in the upper half of every cell.
    d = np.sqrt(((x / w - 0.5) / 0.52) ** 2 + ((y / h - 0.46) / 0.56) ** 2)
    fade = 1 - smoothstep(0.66, 1.0, d)
    rgba = np.asarray(img).astype(float)
    rgba[..., 3] *= fade
    return Image.fromarray(rgba.clip(0, 255).astype(np.uint8), "RGBA")


def avatar(cell: Image.Image) -> Image.Image:
    """Round crop of the face, antialiased by drawing the mask at 4x."""
    w, h = cell.size
    r = 0.40 * w
    cx, cy = 0.5 * w, 0.47 * h
    box = (int(cx - r), int(cy - r), int(cx + r), int(cy + r))
    face = cell.convert("RGBA").crop(box).resize((AVATAR_SIDE, AVATAR_SIDE), Image.LANCZOS)
    big = AVATAR_SIDE * 4
    y, x = np.mgrid[0:big, 0:big]
    inside = ((x - big / 2 + 0.5) ** 2 + (y - big / 2 + 0.5) ** 2) <= (big / 2 - 2) ** 2
    mask = Image.fromarray((inside * 255).astype(np.uint8), "L").resize((AVATAR_SIDE, AVATAR_SIDE), Image.LANCZOS)
    alpha = np.asarray(face)[..., 3].astype(float) * (np.asarray(mask).astype(float) / 255)
    rgba = np.asarray(face).copy()
    rgba[..., 3] = alpha.astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def lifter(work: Path) -> Path:
    """Compile the Vision lift helper once into a scratch folder."""
    source = Path(__file__).with_name("lift-subject.swift")
    binary = work / "lift-subject"
    result = subprocess.run(["swiftc", "-O", str(source), "-o", str(binary)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"Could not build the subject-lift helper (needs Xcode tools, macOS 14+):\n{result.stderr}")
    return binary


def lift(cell: Image.Image, binary: Path, work: Path, index: int) -> Image.Image:
    """The character off its ground, same canvas as the cell."""
    src, dst = work / f"cell-{index:02d}.png", work / f"lifted-{index:02d}.png"
    cell.convert("RGB").save(src)
    result = subprocess.run([str(binary), str(src), str(dst)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"Cell {index}: {result.stderr.strip() or 'lift failed'}")
    return Image.open(dst).convert("RGBA").resize(cell.size, Image.LANCZOS)


def sticker(lifted: Image.Image, side: int) -> Image.Image:
    """Die-cut sticker: a white edge grown out of the silhouette, and one soft
    shadow under it, baked in so the app draws a single bitmap."""
    pad = round(side * 0.05)
    inner = side - 2 * pad
    art = lifted.resize((inner, inner), Image.LANCZOS)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    placed = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    placed.paste(art, (pad, pad))
    alpha = placed.getchannel("A").point(lambda a: 255 if a > 40 else 0)
    edge = max(3, round(side * 0.014)) * 2 + 1
    rim = alpha.filter(ImageFilter.MaxFilter(edge)).filter(ImageFilter.GaussianBlur(side / 480))
    shadow = rim.filter(ImageFilter.GaussianBlur(side / 90)).point(lambda a: a * 0.22)
    offset = Image.new("L", (side, side), 0)
    offset.paste(shadow, (0, round(side * 0.012)))
    canvas.paste((40, 34, 52, 255), (0, 0), offset)
    white = Image.new("RGBA", (side, side), (255, 255, 255, 255))
    canvas.paste(white, (0, 0), rim)
    canvas.alpha_composite(placed)
    return canvas


def avatar_on_disc(lifted: Image.Image) -> Image.Image:
    """The face crop of a lifted cell, on a pale disc so it reads as a coin."""
    disc = Image.new("RGBA", lifted.size, (252, 236, 244, 255))
    disc.alpha_composite(lifted)
    return avatar(disc)


def inside_git_tree(path: Path) -> bool:
    probe = path if path.exists() else path.parent
    while not probe.exists():
        probe = probe.parent
    result = subprocess.run(["git", "-C", str(probe), "rev-parse", "--is-inside-work-tree"],
                            capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip() == "true"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("sheet", type=Path)
    parser.add_argument("--name", required=True, help="pack folder name, e.g. evernight")
    parser.add_argument("--title", help="display name shown in Settings")
    parser.add_argument("--map", type=Path, help="JSON object: mascot mood raw value -> 1-based cell number")
    parser.add_argument("--out", type=Path, help="override the output directory")
    parser.add_argument("--skin", choices=["nocturne", "aubade"], default="nocturne",
                        help="the theme this character plays in (default: nocturne)")
    parser.add_argument("--cutout", action="store_true",
                        help="lift the character off each cell's ground (for a light theme)")
    args = parser.parse_args()

    out = args.out or Path.home() / "Library/Application Support/AIMonitor/Skins" / args.name
    out = out.expanduser().resolve()
    if inside_git_tree(out):
        sys.exit(f"Refusing to write character art inside a git working tree: {out}")

    sheet = Image.open(args.sheet)
    found = cells(sheet)
    out.mkdir(parents=True, exist_ok=True)
    if args.cutout:
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            binary = lifter(work)
            for i, cell in enumerate(found, start=1):
                lifted = lift(cell, binary, work, i)
                sticker(lifted, PORTRAIT_SIDE).save(out / f"sticker-{i:02d}.png", optimize=True)
                sticker(lifted, AVATAR_SIDE).save(out / f"sticker-small-{i:02d}.png", optimize=True)
                avatar_on_disc(lifted).save(out / f"avatar-{i:02d}.png", optimize=True)
    else:
        for i, cell in enumerate(found, start=1):
            portrait(cell).save(out / f"portrait-{i:02d}.png", optimize=True)
            avatar(cell).save(out / f"avatar-{i:02d}.png", optimize=True)

    moods = json.loads(args.map.read_text()) if args.map else {}
    bad = {k: v for k, v in moods.items() if not (isinstance(v, int) and 1 <= v <= len(found))}
    if bad:
        sys.exit(f"Mood map points at cells that do not exist (1…{len(found)}): {bad}")
    manifest = {"name": args.name, "title": args.title or args.name, "cells": len(found), "moods": moods,
                "skin": args.skin, "style": "sticker" if args.cutout else "portrait"}
    (out / "skin.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"{len(found)} cells → {out}")


if __name__ == "__main__":
    main()

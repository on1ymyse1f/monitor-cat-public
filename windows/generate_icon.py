"""Generate the Windows executable icon from the shared menu-bar artwork."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


ICON_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def default_paths() -> tuple[Path, Path]:
    windows_root = Path(__file__).resolve().parent
    repository_root = windows_root.parent
    source = repository_root / "Sources" / "aimonitor-app" / "Resources" / "menubar-cat.png"
    output = windows_root / "build" / "AIMonitor.ico"
    return source, output


def generate_icon(source: Path, output: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(f"icon source does not exist: {source}")

    output.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source) as opened:
        artwork = opened.convert("RGBA")

    # Give the tray drawing a small transparent safe area so Windows does not
    # crop it when producing the smallest icon frames.
    canvas = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    artwork.thumbnail((224, 224), Image.Resampling.LANCZOS)
    origin = ((canvas.width - artwork.width) // 2, (canvas.height - artwork.height) // 2)
    canvas.alpha_composite(artwork, origin)
    canvas.save(output, format="ICO", sizes=[(size, size) for size in ICON_SIZES])


def main() -> int:
    default_source, default_output = default_paths()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=default_source)
    parser.add_argument("--output", type=Path, default=default_output)
    args = parser.parse_args()

    generate_icon(args.source.resolve(), args.output.resolve())
    print(f"Windows icon written to {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

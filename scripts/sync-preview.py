#!/usr/bin/env python3
"""Keep the marketplace preview and the documented screenshot identical.

`manifest.json` does not name the preview image, but the marketplace listing
uses the repository-root `preview.png`, while the README embeds
`docs/screenshots/screenshot-connected.png`. They were a manual copy of the
same capture and had already drifted once, so this script owns the link.

Usage:
    python3 scripts/sync-preview.py --check   # CI/release gate (default)
    python3 scripts/sync-preview.py --write   # refresh preview.png
    python3 scripts/sync-preview.py --from CAPTURE.png   # replace both
"""

import argparse
import hashlib
import shutil
import sys
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
PREVIEW = ROOT / "preview.png"
CANONICAL = ROOT / "docs" / "screenshots" / "screenshot-connected.png"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check() -> int:
    for path in (PREVIEW, CANONICAL):
        if not path.is_file():
            print(f"missing image: {path.relative_to(ROOT)}", file=sys.stderr)
            return 1
    if digest(PREVIEW) != digest(CANONICAL):
        print(
            "preview.png and docs/screenshots/screenshot-connected.png differ.\n"
            "Run: python3 scripts/sync-preview.py --write",
            file=sys.stderr,
        )
        return 1
    print(f"preview in sync: {digest(PREVIEW)[:16]}…")
    return 0


def write(source: Optional[Path] = None) -> int:
    source = source or CANONICAL
    if not source.is_file():
        print(f"missing source image: {source}", file=sys.stderr)
        return 1
    CANONICAL.parent.mkdir(parents=True, exist_ok=True)
    if source.resolve() != CANONICAL.resolve():
        shutil.copyfile(source, CANONICAL)
    shutil.copyfile(CANONICAL, PREVIEW)
    print(f"synchronized {PREVIEW.relative_to(ROOT)} from {CANONICAL.relative_to(ROOT)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="fail when the images differ (default)")
    group.add_argument("--write", action="store_true", help="copy the documented screenshot to preview.png")
    group.add_argument("--from", dest="source", type=Path, help="replace both images from a capture")
    args = parser.parse_args()
    if args.write or args.source:
        return write(args.source)
    return check()


if __name__ == "__main__":
    raise SystemExit(main())

"""Package a distributable mod zip into releases/.

The zip contains a top-level EmperorsTouch/ folder (so users extract it
straight into their game's mods/ directory) with only the runtime files —
whitelisted, so dev clutter (darktide-ws, docs, logs) can never leak in.

Output: releases/EmperorsTouch-<hash>.zip where <hash> is the first 5
hex digits of the current commit ("-dirty" appended if the working tree
has uncommitted changes).
"""

import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).parent
RELEASES = ROOT / "releases"

# Runtime files/dirs only; everything else stays out of the zip.
INCLUDE = [
    "EmperorsTouch.mod",
    "scripts",
    "bin",
]


def git(*args):
    return subprocess.check_output(("git", "-C", str(ROOT)) + args, text=True).strip()


def main():
    tag = git("rev-parse", "--short=5", "HEAD")
    if git("status", "--porcelain"):
        tag += "-dirty"

    RELEASES.mkdir(exist_ok=True)
    out = RELEASES / f"EmperorsTouch-{tag}.zip"

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in INCLUDE:
            path = ROOT / name
            if not path.exists():
                raise FileNotFoundError(f"Missing release file: {path}")
            files = [path] if path.is_file() else sorted(p for p in path.rglob("*") if p.is_file())
            for f in files:
                zf.write(f, Path("EmperorsTouch") / f.relative_to(ROOT))

    size_mb = out.stat().st_size / 1e6
    print(f"Wrote {out} ({size_mb:.1f} MB, {len(zipfile.ZipFile(out).namelist())} files)")


if __name__ == "__main__":
    main()

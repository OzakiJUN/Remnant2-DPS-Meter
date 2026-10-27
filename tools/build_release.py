"""Build the release package dist/R2DPS_Setup_v<version>.zip.

Needs the UE4SS zip in R2DPS_Setup/setup/ue4ss_bundle/ (not stored in git, see THIRD_PARTY_NOTICES.md).
The version comes from VERSION in R2DPS_Setup/setup/R2DPS/Scripts/main.lua.
Usage: python tools/build_release.py   (or double-click tools/build_release.bat on Windows)
"""
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / "R2DPS_Setup"
MAIN = PKG / "setup" / "R2DPS" / "Scripts" / "main.lua"
BUNDLE = PKG / "setup" / "ue4ss_bundle"
NEED = b"LoopInGameThreadWithDelay"   # game-thread timer R2DPS needs
SKIP_NAMES = {"R2DPS_debug.txt", "names_todo.txt"}


def fail(msg):
    print("ERROR: " + msg)
    sys.exit(1)


def main():
    m = re.search(r'local VERSION = "([^"]+)"', MAIN.read_text(encoding="utf-8"))
    if not m:
        fail("VERSION not found in " + str(MAIN))
    version = m.group(1)

    zips = sorted(BUNDLE.glob("*.zip"))
    if len(zips) != 1:
        fail("put exactly one UE4SS zip into " + str(BUNDLE) + " (found %d)" % len(zips))
    with zipfile.ZipFile(zips[0]) as z:
        dlls = [n for n in z.namelist() if n.lower().endswith("ue4ss.dll")]
        if not dlls:
            fail(zips[0].name + " has no UE4SS.dll")
        if NEED not in z.read(dlls[0]):
            fail(zips[0].name + " is too old: no " + NEED.decode())

    out_dir = ROOT / "dist"
    out_dir.mkdir(exist_ok=True)
    out = out_dir / ("R2DPS_Setup_v%s.zip" % version)
    files = [p for p in sorted(PKG.rglob("*")) if p.is_file() and p.name not in SKIP_NAMES and p.suffix != ".dmp"]
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in files:
            z.write(p, p.relative_to(ROOT).as_posix())
        for extra in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            z.write(ROOT / extra, "R2DPS_Setup/" + extra)
    print("built %s (%d files, %.1f MB) with %s" % (out, len(files) + 2, out.stat().st_size / 1048576, zips[0].name))


if __name__ == "__main__":
    main()

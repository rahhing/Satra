#!/usr/bin/env python3
"""Render the default white Satra mark for each platform.

Requires rsvg-convert and ImageMagick. Stable filenames and alternate icon IDs
are retained so packaging, saved icon choices, and upgrades continue to work.
"""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "assets/satra.svg"


def run(*args):
    if args[0] == "magick":
        args = (*args[:-1], "-strip", args[-1])
    subprocess.run([str(arg) for arg in args], check=True)


def dimensions(path):
    result = subprocess.check_output(["magick", "identify", "-format", "%w %h", str(path)], text=True)
    return tuple(map(int, result.split()))


def main():
    for command in ("rsvg-convert", "magick"):
        if not shutil.which(command):
            raise SystemExit(f"Missing {command}")

    with tempfile.TemporaryDirectory(prefix="satra-brand-") as temp:
        raster = Path(temp) / "mark.png"
        run("rsvg-convert", "-w", 1024, "-h", 1024, SOURCE, "-o", raster)
        run("magick", raster, "-resize", "512x512", ROOT / "assets/satra.png")
        for alias in ("satra.svg", "satra_adaptive_foreground.svg"):
            (ROOT / "assets" / alias).write_text(SOURCE.read_text())

        def canvas(path, width, height, *, black=True):
            extent = round(min(width, height) * 0.82)
            opaque = ("-background", "black", "-alpha", "remove", "-alpha", "off") if black else ()
            run("magick", raster, "-resize", f"{extent}x{extent}", *opaque, "-gravity", "center",
                "-background", "black" if black else "transparent", "-extent", f"{width}x{height}", path)

        res = ROOT / "android/app/src/main/res"
        for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
            canvas(res / f"mipmap-{density}/ic_launcher.png", size, size)
            notification = res / f"drawable-{density}/ic_stat_notification.png"
            if notification.exists():
                canvas(notification, size // 2, size // 2, black=False)

        path_data = ET.parse(SOURCE).getroot().find("{http://www.w3.org/2000/svg}path").attrib["d"]
        vector = f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
  <group android:scaleX="0.15" android:scaleY="0.15" android:translateX="17.55" android:translateY="11.7">
    <path android:fillColor="#FFFFFFFF" android:pathData="{path_data}"/>
  </group>
</vector>
'''
        for name in ("ic_launcher_foreground.xml", "ic_launcher_monochrome.xml"):
            (res / "drawable" / name).write_text(vector)

        for path in res.glob("drawable-*/tv_banner.png"):
            canvas(path, *dimensions(path))
        for path in (ROOT / "assets/app_icons/previews").glob("default-*.webp"):
            canvas(path, *dimensions(path))

        for platform in ("ios", "macos"):
            icon = ROOT / platform / "satra.icon"
            (icon / "Assets/satra-cropped.svg").write_text(SOURCE.read_text())
            config = json.loads((icon / "icon.json").read_text())
            config["fill"]["solid"] = "gray:0.00000,1.00000"
            (icon / "icon.json").write_text(json.dumps(config, indent=2) + "\n")

        tv = ROOT / "tvos/Runner/Assets.xcassets/AppIcon.brandassets"
        for path in tv.rglob("*.png"):
            width, height = dimensions(path)
            if "Back.imagestacklayer" in str(path):
                run("magick", "-size", f"{width}x{height}", "xc:black", path)
            elif "Middle.imagestacklayer" in str(path):
                run("magick", "-size", f"{width}x{height}", "xc:none", path)
            else:
                canvas(path, width, height, black="Front.imagestacklayer" not in str(path))

        run("magick", raster, "-background", "black", "-alpha", "remove",
            "-define", "icon:auto-resize=256,128,64,48,32,16", ROOT / "windows/runner/resources/app_icon.ico")


if __name__ == "__main__":
    main()

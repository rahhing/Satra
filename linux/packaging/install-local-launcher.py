#!/usr/bin/env python3
"""Point the current user's desktop launcher at a locally built Satra bundle.

Keep the GTK application ID so existing profiles and desktop grouping survive.
Wayland taskbars resolve this desktop entry's icon instead of GTK's window icon.
"""

import argparse
import os
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="Flutter Linux bundle directory")
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    executable = bundle / "satra"
    icon = bundle / "data/flutter_assets/assets/satra.png"
    svg_icon = bundle / "data/flutter_assets/assets/satra.svg"
    if not svg_icon.is_file():
        svg_icon = bundle / "data/flutter_assets/assets/satra.svg"
    if not executable.is_file() or not os.access(executable, os.X_OK) or not icon.is_file():
        parser.error("Expected an executable satra and bundled assets/satra.png")

    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    applications = data_home / "applications"
    applications.mkdir(parents=True, exist_ok=True)

    # Install user-local hicolor icons so XDG/KDE/KRunner override any stale
    # system-wide /usr/share/icons/hicolor/*/apps/satra.* entries.
    hicolor = data_home / "icons/hicolor"
    png_apps = hicolor / "1024x1024/apps"
    scalable_apps = hicolor / "scalable/apps"
    png_apps.mkdir(parents=True, exist_ok=True)
    scalable_apps.mkdir(parents=True, exist_ok=True)
    for icon_name in ("satra", "satra", "com.edde746.satra"):
        shutil.copy2(icon, png_apps / f"{icon_name}.png")
        if svg_icon.is_file():
            shutil.copy2(svg_icon, scalable_apps / f"{icon_name}.svg")
    installed_icon = png_apps / "satra.png"

    desktop = applications / "com.edde746.satra.desktop"
    # Back up a pre-existing user customization once; never alter system files.
    backup = desktop.with_suffix(".desktop.before-satra")
    if desktop.exists() and not backup.exists() and "X-Satra-Local=true" not in desktop.read_text():
        shutil.copy2(desktop, backup)

    def value(text):
        return str(text).replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")

    # Exec's quoting is distinct from desktop-entry string escaping.
    quoted = str(executable).replace("%", "%%")
    for char in ("\\", '"', "`", "$"):
        quoted = quoted.replace(char, "\\" + char)
    desktop.write_text(
        "[Desktop Entry]\nType=Application\nName=Satra\n"
        "Comment=A modern Plex and Jellyfin client for desktop and mobile\n"
        f'Exec="{value(quoted)}"\nIcon={value(installed_icon)}\n'
        "Terminal=false\nCategories=AudioVideo;Video;Player;\n"
        "Keywords=plex;jellyfin;emby;media;streaming;video;\n"
        "StartupWMClass=com.edde746.satra\nX-Satra-Local=true\n",
        encoding="utf-8",
    )
    updater = shutil.which("update-desktop-database")
    if updater:
        subprocess.run([updater, str(applications)], check=True)
    icon_cache_updater = shutil.which("gtk-update-icon-cache")
    if icon_cache_updater:
        subprocess.run([icon_cache_updater, "-f", "-t", str(hicolor)], check=False)
    cache_home = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    kde_icon_cache = cache_home / "icon-cache.kcache"
    if kde_icon_cache.is_file():
        kde_icon_cache.unlink(missing_ok=True)
    for sycoca in ("kbuildsycoca6", "kbuildsycoca5"):
        sycoca_bin = shutil.which(sycoca)
        if sycoca_bin:
            subprocess.run([sycoca_bin, "--noincremental"], check=False)
            break
    systemctl_bin = shutil.which("systemctl")
    if systemctl_bin:
        subprocess.run([systemctl_bin, "--user", "try-restart", "plasma-krunner.service"], check=False)
    print(f"Installed Satra launcher: {desktop}")


if __name__ == "__main__":
    main()

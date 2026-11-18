#!/usr/bin/env python3
"""Render AltStore & SideStore source manifests plus a one-tap sideloading page."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import plistlib
import urllib.parse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--info-plist", required=True, type=Path)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument(
        "--site-url",
        default=os.environ.get("SATRA_IOS_SITE_URL", "https://rahhing.github.io/Satra"),
    )
    parser.add_argument(
        "--download-url",
        default=os.environ.get("SATRA_IOS_DOWNLOAD_URL", ""),
    )
    parser.add_argument(
        "--repo-url",
        default=os.environ.get("SATRA_REPO_URL", "https://github.com/rahhing/Satra"),
    )
    parser.add_argument(
        "--notes",
        default=os.environ.get(
            "SATRA_IOS_RELEASE_NOTES",
            "Native iOS Liquid Glass UI refinements, flush top-right menu pill, aligned bottom Search orb, and progressive Continue Watching backdrop darkening.",
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    with args.info_plist.open("rb") as fh:
        info = plistlib.load(fh)

    site_url = args.site_url.rstrip("/")
    repo_url = args.repo_url.rstrip("/")
    source_url = f"{site_url}/source.json"
    icon_url = f"{site_url}/icon.png"

    version = str(info.get("CFBundleShortVersionString", "2.26.0"))
    build_version = str(info.get("CFBundleVersion", "160"))
    bundle_id = str(info.get("CFBundleIdentifier", "com.rahhing.satra"))
    app_name = str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or "Satra")
    min_os = str(info.get("MinimumOSVersion", "15.5"))

    download_url = args.download_url.strip() or f"{site_url}/{args.ipa.name}"
    ipa_bytes = args.ipa.read_bytes()
    sha256 = hashlib.sha256(ipa_bytes).hexdigest()
    size = len(ipa_bytes)
    now_iso = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    privacy_keys = [
        "NSCameraUsageDescription",
        "NSLocalNetworkUsageDescription",
        "NSLocationWhenInUseUsageDescription",
        "NSPhotoLibraryUsageDescription",
    ]
    privacy = {key: str(info[key]) for key in privacy_keys if key in info}

    version_entry = {
        "version": version,
        "buildVersion": build_version,
        "date": now_iso,
        "localizedDescription": args.notes,
        "downloadURL": download_url,
        "size": size,
        "sha256": sha256,
        "minOSVersion": min_os,
    }

    manifest = {
        "name": "Satra",
        "identifier": f"{bundle_id}.source",
        "subtitle": "Plex & Jellyfin Media Player for iOS",
        "description": "Official AltStore & SideStore source for Satra on iOS and iPadOS.",
        "iconURL": icon_url,
        "website": repo_url,
        "tintColor": "#38BDF8",
        "featuredApps": [bundle_id],
        "apps": [
            {
                "name": app_name,
                "bundleIdentifier": bundle_id,
                "developerName": "Satra",
                "subtitle": "Beautiful Plex & Jellyfin client",
                "localizedDescription": (
                    "Satra is a fast, native Liquid Glass media player for Plex and Jellyfin "
                    "on iOS, iPadOS, macOS, and TV with HDR playback, offline downloads, "
                    "Watch Together, and multi-server profiles."
                ),
                "iconURL": icon_url,
                "tintColor": "#38BDF8",
                "category": "entertainment",
                "beta": False,
                "downloadURL": download_url,
                "version": version,
                "buildVersion": build_version,
                "versionDate": now_iso,
                "versionDescription": args.notes,
                "size": size,
                "sha256": sha256,
                "minOSVersion": min_os,
                "appPermissions": {
                    "entitlements": [],
                    "privacy": privacy,
                },
                "versions": [version_entry],
            }
        ],
        "news": [],
    }

    args.out_dir.mkdir(parents=True, exist_ok=True)
    rendered_json = json.dumps(manifest, indent=2) + "\n"
    for filename in ("source.json", "altstore.json", "sidestore.json", "altstore-source.json"):
        (args.out_dir / filename).write_text(rendered_json, encoding="utf-8")

    encoded_source = urllib.parse.quote(source_url, safe="")
    sidestore_deep_link = f"sidestore://source?url={encoded_source}"
    altstore_deep_link = f"altstore://source?url={encoded_source}"
    size_mb = size / (1024 * 1024)

    page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>{html.escape(app_name)} — AltStore &amp; SideStore Source</title>
  <link rel="icon" href="icon.png">
  <style>
    :root {{
      color-scheme: dark;
      --bg: #050608;
      --card: rgba(20, 23, 31, 0.78);
      --border: rgba(255, 255, 255, 0.12);
      --text: #f8fafc;
      --muted: #94a3b8;
      --accent: #38bdf8;
      --sidestore: #6366f1;
      --altstore: #0ea5e9;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100dvh;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", sans-serif;
      background:
        radial-gradient(circle at 50% -10%, rgba(56, 189, 248, 0.22), transparent 55%),
        radial-gradient(circle at 85% 95%, rgba(99, 102, 241, 0.16), transparent 45%),
        var(--bg);
      color: var(--text);
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 24px 16px;
    }}
    main {{
      width: 100%;
      max-width: 480px;
      background: var(--card);
      backdrop-filter: blur(28px);
      -webkit-backdrop-filter: blur(28px);
      border: 1px solid var(--border);
      border-radius: 28px;
      padding: 28px 24px;
      box-shadow: 0 24px 64px rgba(0, 0, 0, 0.55);
    }}
    .header {{
      display: flex;
      align-items: center;
      gap: 16px;
      margin-bottom: 18px;
    }}
    .icon {{
      width: 72px;
      height: 72px;
      border-radius: 18px;
      border: 1px solid var(--border);
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    }}
    h1 {{
      font-size: 1.65rem;
      font-weight: 700;
      letter-spacing: -0.03em;
      margin: 0 0 4px;
    }}
    .meta {{
      color: var(--muted);
      font-size: 0.9rem;
    }}
    p.desc {{
      color: #cbd5e1;
      font-size: 0.95rem;
      line-height: 1.5;
      margin: 0 0 22px;
    }}
    .actions {{
      display: grid;
      gap: 11px;
      margin-bottom: 20px;
    }}
    .btn {{
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      width: 100%;
      padding: 14px 18px;
      border-radius: 999px;
      font-weight: 600;
      font-size: 0.98rem;
      text-decoration: none;
      color: #fff;
      border: 1px solid rgba(255, 255, 255, 0.14);
      transition: transform 0.12s ease, opacity 0.12s ease;
    }}
    .btn:active {{ transform: scale(0.98); opacity: 0.9; }}
    .btn-sidestore {{ background: linear-gradient(135deg, #6366f1, #4f46e5); }}
    .btn-altstore {{ background: linear-gradient(135deg, #0ea5e9, #0284c7); }}
    .btn-ipa {{
      background: rgba(255, 255, 255, 0.08);
      color: var(--text);
    }}
    .source-box {{
      background: rgba(0, 0, 0, 0.38);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 12px 14px;
    }}
    .source-label {{
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--muted);
      margin-bottom: 6px;
    }}
    .source-row {{
      display: flex;
      align-items: center;
      gap: 8px;
    }}
    code {{
      flex: 1;
      font-size: 0.82rem;
      color: var(--accent);
      word-break: break-all;
    }}
    button.copy {{
      background: rgba(255, 255, 255, 0.1);
      color: var(--text);
      border: 1px solid var(--border);
      border-radius: 999px;
      padding: 6px 12px;
      font-size: 0.8rem;
      font-weight: 600;
      cursor: pointer;
      white-space: nowrap;
    }}
    footer {{
      margin-top: 18px;
      text-align: center;
      font-size: 0.8rem;
      color: var(--muted);
    }}
    footer a {{ color: var(--muted); }}
  </style>
</head>
<body>
  <main>
    <div class="header">
      <img class="icon" src="icon.png" alt="{html.escape(app_name)} icon">
      <div>
        <h1>{html.escape(app_name)}</h1>
        <div class="meta">v{html.escape(version)} ({html.escape(build_version)}) &bull; {size_mb:.1f} MB &bull; iOS {html.escape(min_os)}+</div>
      </div>
    </div>
    <p class="desc">{html.escape(args.notes)}</p>
    <div class="actions">
      <a class="btn btn-sidestore" href="{html.escape(sidestore_deep_link)}">Add Source to SideStore</a>
      <a class="btn btn-altstore" href="{html.escape(altstore_deep_link)}">Add Source to AltStore</a>
      <a class="btn btn-ipa" href="{html.escape(download_url)}">Download IPA Directly</a>
    </div>
    <div class="source-box">
      <div class="source-label">Source URL (AltStore / SideStore / Feather)</div>
      <div class="source-row">
        <code id="source-url">{html.escape(source_url)}</code>
        <button class="copy" type="button" onclick="navigator.clipboard.writeText(document.getElementById('source-url').textContent).then(() => {{ this.textContent = 'Copied!'; setTimeout(() => this.textContent = 'Copy', 1800); }})">Copy</button>
      </div>
    </div>
    <footer>
      <a href="{html.escape(repo_url)}">GitHub Repository</a> &bull; SHA-256: {sha256[:12]}&hellip;
    </footer>
  </main>
</body>
</html>
"""
    (args.out_dir / "index.html").write_text(page, encoding="utf-8")
    (args.out_dir / ".nojekyll").write_text("", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/bin/bash
# Build and update the stable Finder/Dock application.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This installer requires macOS.' >&2
  exit 1
fi
flutter_bin="${FLUTTER_ROOT:+$FLUTTER_ROOT/bin/}flutter"
if [[ -z "${FLUTTER_ROOT:-}" && -x "$PWD/.tools/flutter/bin/flutter" ]]; then
  flutter_bin="$PWD/.tools/flutter/bin/flutter"
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! command -v "$flutter_bin" >/dev/null 2>&1; then
  echo 'Flutter is required. Add Flutter to PATH or set FLUTTER_ROOT to its SDK directory.' >&2
  exit 1
fi
"$flutter_bin" pub get
"$flutter_bin" build macos --release
source_app="$PWD/build/macos/Build/Products/Release/Satra.app"
target_app='/Applications/Satra.app'
[[ -d "$source_app" ]] || { echo "Missing build: $source_app" >&2; exit 1; }
# Incremental Flutter builds can update App.framework without refreshing the
# runner's resource seal. Refresh this local build's ad-hoc signature.
/usr/bin/codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$source_app"
/usr/bin/codesign --verify --deep --strict "$source_app"
# Do not replace files while the installed executable is using them.
if pgrep -f '^/Applications/Satra.app/Contents/MacOS/Satra' >/dev/null; then
  echo 'Quit Satra, then run this command again to install the completed build.' >&2
  exit 1
fi
/usr/bin/rsync -a --checksum --delete "$source_app/" "$target_app/"
/usr/bin/codesign --verify --deep --strict "$target_app"
/usr/bin/touch "$target_app"
echo "Updated $target_app. Open it from Applications or your existing Dock icon."

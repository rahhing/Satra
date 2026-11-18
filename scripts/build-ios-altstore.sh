#!/usr/bin/env bash
# Build an ad-hoc-sealed release iOS IPA and AltStore/SideStore source bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This build script requires macOS with Xcode.' >&2
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

git_commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

"$flutter_bin" pub get
"$flutter_bin" build ios \
  --release \
  --no-codesign \
  --dart-define=ENABLE_UPDATE_CHECK=true \
  --dart-define=GIT_COMMIT="$git_commit" \
  --dart-define=ENABLE_DONATIONS=true \
  --split-debug-info=build/ios/debug-info

source_app="$PWD/build/ios/iphoneos/Satra.app"
[[ -d "$source_app" ]] || { echo "Missing iOS app bundle: $source_app" >&2; exit 1; }

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/satra-altstore-ipa.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT

payload_app="$stage_dir/Payload/Satra.app"
mkdir -p "$stage_dir/Payload"
/usr/bin/ditto --noextattr --norsrc "$source_app" "$payload_app"
chmod -R u+rwX,go+rX "$payload_app"
/usr/bin/xattr -cr "$payload_app" 2>/dev/null || true

if [[ -d "$payload_app/Frameworks" ]]; then
  shopt -s nullglob
  for fw in "$payload_app/Frameworks"/*.framework "$payload_app/Frameworks"/*.dylib; do
    /usr/bin/codesign --force --sign - --timestamp=none "$fw"
  done
  shopt -u nullglob
fi

/usr/bin/codesign --force --sign - --timestamp=none "$payload_app"
/usr/bin/codesign --verify --deep --strict "$payload_app"

out_dir="$PWD/build/ios/ipa"
mkdir -p "$out_dir"
ipa_path="$out_dir/Satra-AltStore.ipa"
rm -f "$ipa_path" "$out_dir/Satra.ipa"

(
  cd "$stage_dir"
  /usr/bin/zip -qry "$ipa_path" Payload
)
cp -f "$ipa_path" "$out_dir/Satra.ipa"

if [[ -f "$PWD/ios/Runner/AlternateAppIcons.xcassets/AppIcon-oled.appiconset/icon.png" ]]; then
  cp -f "$PWD/ios/Runner/AlternateAppIcons.xcassets/AppIcon-oled.appiconset/icon.png" "$out_dir/icon.png"
elif [[ -f "$payload_app/satra76x76@2x~ipad.png" ]]; then
  cp -f "$payload_app/satra76x76@2x~ipad.png" "$out_dir/icon.png"
fi

# Generate AltStore v1/v2 + SideStore compatible manifests and landing page.
python3 "$PWD/scripts/render_ios_source.py" \
  --info-plist "$payload_app/Info.plist" \
  --ipa "$ipa_path" \
  --out-dir "$out_dir"

echo "Built AltStore IPA: $ipa_path ($(du -h "$ipa_path" | awk '{print $1}'))"
echo "Built AltStore/SideStore source manifest: $out_dir/source.json"

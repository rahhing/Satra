#!/usr/bin/env bash
# Publish the built iOS IPA to GitHub Releases and deploy the AltStore/SideStore
# source (source.json + one-tap landing page) to GitHub Pages (gh-pages branch).
set -euo pipefail

cd "$(dirname "$0")/.."

repo="${SATRA_GITHUB_REPO:-rahhing/Satra}"
owner="${repo%%/*}"
repo_name="${repo##*/}"
site_url="${SATRA_IOS_SITE_URL:-https://${owner}.github.io/${repo_name}}"
repo_url="https://github.com/${repo}"

ipa_dir="$PWD/build/ios/ipa"
ipa_path="$ipa_dir/Satra-AltStore.ipa"
alt_ipa_path="$ipa_dir/Satra.ipa"
info_plist="$PWD/build/ios/iphoneos/Satra.app/Info.plist"

if [[ ! -f "$ipa_path" || ! -f "$info_plist" ]]; then
  echo "Building iOS IPA first..."
  bash "$PWD/scripts/build-ios-altstore.sh"
fi

read -r version build_version < <(
  python3 - "$info_plist" <<'PY'
import plistlib, sys
from pathlib import Path
with Path(sys.argv[1]).open("rb") as fh:
    info = plistlib.load(fh)
print(info.get("CFBundleShortVersionString", "2.26.0"), info.get("CFBundleVersion", "160"))
PY
)

release_tag="${1:-ios-v${version}-${build_version}}"
download_url="${repo_url}/releases/download/${release_tag}/Satra-AltStore.ipa"

# Upload IPA assets to a pre-release tag so desktop-only package workflows skip it
# while keeping permanent public HTTPS release asset URLs for AltStore & SideStore.
if gh release view "$release_tag" --repo "$repo" >/dev/null 2>&1; then
  gh release upload "$release_tag" "$ipa_path" "$alt_ipa_path" --clobber --repo "$repo"
else
  gh release create "$release_tag" "$ipa_path" "$alt_ipa_path" \
    --repo "$repo" \
    --prerelease \
    --title "Satra iOS ${version} (${build_version})" \
    --notes "Unsigned/ad-hoc sealed iOS release IPA for AltStore and SideStore.

Source URL: ${site_url}/source.json
One-tap install page: ${site_url}/"
fi

python3 "$PWD/scripts/render_ios_source.py" \
  --info-plist "$info_plist" \
  --ipa "$ipa_path" \
  --out-dir "$ipa_dir" \
  --site-url "$site_url" \
  --download-url "$download_url" \
  --repo-url "$repo_url"

# Commit static source files (NO bulky IPA binaries in git!) to orphan gh-pages branch.
tree_input="$(mktemp "${TMPDIR:-/tmp}/satra-gh-pages.XXXXXX")"
trap 'rm -f "$tree_input"' EXIT

for file in source.json altstore.json sidestore.json altstore-source.json index.html icon.png .nojekyll; do
  [[ -f "$ipa_dir/$file" ]] || continue
  blob="$(git hash-object -w "$ipa_dir/$file")"
  printf "100644 blob %s\t%s\n" "$blob" "$file" >> "$tree_input"
done

tree="$(git mktree < "$tree_input")"
commit="$(git commit-tree "$tree" -m "Publish AltStore/SideStore source for ${release_tag}")"
git push origin "$commit:refs/heads/gh-pages" --force

# Ensure GitHub Pages is enabled on gh-pages.
if ! gh api "repos/${repo}/pages" >/dev/null 2>&1; then
  gh api -X POST "repos/${repo}/pages" \
    -f "source[branch]=gh-pages" \
    -f "source[path]=/" >/dev/null
fi

echo "Published release: ${repo_url}/releases/tag/${release_tag}"
echo "AltStore / SideStore Source URL: ${site_url}/source.json"
echo "Landing Page: ${site_url}/"

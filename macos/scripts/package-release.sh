#!/bin/bash
# Package a tagged personal Mac helper without installing or starting the app.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tag="${1:?Usage: macos/scripts/package-release.sh vX.Y.Z}"
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo 'Expected a numeric version tag vX.Y.Z.' >&2; exit 1;
}
[[ "$(uname -m)" == arm64 ]] || { echo 'This release channel currently supports Apple silicon.' >&2; exit 1; }
python3 scripts/verify-upstream.py
# Always package inside this checkout, regardless of a local trial destination.
export KEEPRESSO_APP_DESTINATION="$root/macos/artifacts/KeepressoMobile.app"
bash macos/scripts/build-app.sh
app=macos/artifacts/KeepressoMobile.app
build_version=$(python3 scripts/release-version.py "$tag" | sed -n 's/^version_code=//p')
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${tag#v}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp macos/ThirdParty/KeepressoCore/LICENSE "$app/Contents/Resources/Keepresso-LICENSE.txt"
bash macos/scripts/sign-app.sh "$app"
codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/KeepressoMac" -verify_arch arm64
"$app/Contents/MacOS/KeepressoMac" --self-check
ditto -c -k --sequesterRsrc --keepParent "$app" macos/artifacts/KeepressoMobile.zip
(cd macos/artifacts && shasum -a 256 KeepressoMobile.zip > SHA256SUMS)

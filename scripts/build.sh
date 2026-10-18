#!/bin/zsh
# Builds Joule.app (release, ad-hoc signed). Works with the Command Line Tools alone.
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --product Joule
APP=.build/Joule.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Joule "$APP/Contents/MacOS/Joule"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  xcrun swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --options runtime "$APP"
echo "Fertig: $PWD/$APP"

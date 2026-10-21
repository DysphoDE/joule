#!/bin/zsh
# Builds dist/Joule-<version>.dmg (drag to Applications) and a .zip of the app.
set -euo pipefail
cd "${0:A:h:h}"
./scripts/check.sh > /dev/null
./scripts/build.sh
VERSION=$(defaults read "$PWD/.build/Joule.app/Contents/Info.plist" CFBundleShortVersionString)
mkdir -p dist
STAGE=$(mktemp -d)/Joule
mkdir -p "$STAGE"
ditto .build/Joule.app "$STAGE/Joule.app"
ln -s /Applications "$STAGE/Applications"
rm -f "dist/Joule-$VERSION.dmg" "dist/Joule-$VERSION.zip"
hdiutil create -volname "Joule $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Joule-$VERSION.dmg" > /dev/null
ditto -c -k --keepParent .build/Joule.app "dist/Joule-$VERSION.zip"
shasum -a 256 dist/Joule-$VERSION.* | sed "s#dist/##"
echo "Fertig: dist/Joule-$VERSION.dmg, dist/Joule-$VERSION.zip"

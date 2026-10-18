#!/bin/zsh
# Builds Joule and installs or updates /Applications/Joule.app.
# Keeps history, settings and the login item; restarts Joule if it was running.
set -euo pipefail
cd "${0:A:h:h}"
TARGET=/Applications/Joule.app
./scripts/check.sh > /dev/null
./scripts/build.sh

login=aus
if [[ -x "$TARGET/Contents/MacOS/Joule" ]]; then
  login=$("$TARGET/Contents/MacOS/Joule" --login-item status 2>/dev/null || echo aus)
fi
[[ "${1:-}" == "--login" ]] && login=an

# Quit the running copy; at most the current minute is lost.
if pgrep -x Joule > /dev/null; then
  pkill -TERM -x Joule
  for _ in {1..20}; do pgrep -x Joule > /dev/null || break; /bin/sleep 0.25; done
fi

rm -rf "$TARGET"
ditto .build/Joule.app "$TARGET"
if [[ "$login" == an* ]]; then
  echo "Autostart: $("$TARGET/Contents/MacOS/Joule" --login-item on)"
fi
open "$TARGET" --args --background
echo "Installiert: $TARGET ($(defaults read "$TARGET/Contents/Info.plist" CFBundleShortVersionString))"

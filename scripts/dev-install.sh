#!/bin/bash
# Fast loop: native-arch release build swapped into /Applications/Krutilka.app, then relaunched.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release >/dev/null
pkill -x Krutilka 2>/dev/null || true
[[ -d /Applications/Krutilka.app ]] || { echo "Run scripts/build-app.sh --install first"; exit 1; }
cp .build/release/Krutilka /Applications/Krutilka.app/Contents/MacOS/Krutilka
cp -R Resources/en.lproj Resources/ru.lproj /Applications/Krutilka.app/Contents/Resources/
codesign --force --sign - --timestamp=none /Applications/Krutilka.app 2>/dev/null
open /Applications/Krutilka.app
echo "reinstalled"

#!/bin/bash
# Builds build/Krutilka.app for Apple silicon and Intel and signs it ad hoc
# (no paid Apple certificate; without any signature Apple silicon refuses to run it).
#   scripts/build-app.sh            the app only
#   scripts/build-app.sh --dmg      plus dist/Krutilka-<version>-macOS.dmg
#   scripts/build-app.sh --install  plus a copy in /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

DMG=0; INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --dmg) DMG=1 ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done

APP=build/Krutilka.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swift build -c release --product Krutilka --triple "$arch-apple-macosx13.0" --scratch-path ".build/$arch" >/dev/null
done
lipo -create -output "$APP/Contents/MacOS/Krutilka" \
    .build/arm64/release/Krutilka .build/x86_64/release/Krutilka

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Krutilka"))"

if [[ $DMG == 1 ]]; then
    mkdir -p dist
    IMAGE="dist/Krutilka-$VERSION-macOS.dmg"
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Программы"
    rm -f "$IMAGE"
    hdiutil create -volname "Крутилка" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$IMAGE" >/dev/null
    echo "Built $IMAGE"
fi

if [[ $INSTALL == 1 ]]; then
    pkill -x Krutilka 2>/dev/null || true
    rm -rf /Applications/Krutilka.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Krutilka.app"
fi

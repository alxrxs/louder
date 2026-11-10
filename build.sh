#!/bin/bash
# Builds build/Louder.app. Pass "install" to also copy it to /Applications and relaunch.
#   CODESIGN_IDENTITY=-          force an ad-hoc signature (what the Homebrew formula uses)
#   SWIFT_BUILD_FLAGS=...        extra flags for swift build (e.g. --disable-sandbox under brew)
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC2086
swift build -c release ${SWIFT_BUILD_FLAGS:-}

APP=build/Louder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Louder "$APP/Contents/MacOS/Louder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Version comes from the latest vX.Y.Z tag (falling back to Info.plist); the build
# number is the commit count, so every build from a newer commit sorts higher.
PLIST="$APP/Contents/Info.plist"
if TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null); then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TAG#v}" "$PLIST"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$PLIST"

# A stable signing identity keeps the System Audio Recording grant valid across rebuilds;
# ad-hoc signatures change every build and force you to re-grant.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc identity})"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Louder || true
    # Launch Services refuses to open the app while the old copy is still shutting down.
    for _ in {1..50}; do pgrep -x Louder >/dev/null || break; sleep 0.1; done
    rm -rf /Applications/Louder.app
    cp -R "$APP" /Applications/Louder.app
    open /Applications/Louder.app
    echo "Installed to /Applications/Louder.app and launched"
fi

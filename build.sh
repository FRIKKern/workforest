#!/bin/sh
# Builds a universal WorkForest.app into ./build and installs it to ~/Applications.
# Usage: ./build.sh [--no-install]
set -e
cd "$(dirname "$0")"
APP=build/WorkForest.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=13.0 -arch arm64 -arch x86_64 \
  -framework Cocoa -framework ServiceManagement -framework UserNotifications \
  Sources/main.m Sources/Common.m Sources/Rules.m Sources/Trees.m Sources/Review.m Sources/Forest.m -o "$APP/Contents/MacOS/WorkForest"
cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/WorkForest"))"
[ "$1" = "--no-install" ] && exit 0
mkdir -p ~/Applications ~/.local/bin
rm -rf ~/Applications/WorkForest.app
cp -R "$APP" ~/Applications/
ln -sf ~/Applications/WorkForest.app/Contents/MacOS/WorkForest ~/.local/bin/workforest
# URLs such as workforest://quit must reach the installed app, not the copy in ./build.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$PWD/$APP" >/dev/null 2>&1 || true
"$LSREG" -f ~/Applications/WorkForest.app >/dev/null 2>&1 || true
echo "Installed ~/Applications/WorkForest.app and ~/.local/bin/workforest"

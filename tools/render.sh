#!/bin/sh
# Renders the menu and hover cards to PNG: tools/render.sh [output folder], default build/render.
# main.m is compiled with -Dmain=xx_main so tools/render.m can drive the menu code without starting the app.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/render}"
B=build/render-bin; mkdir -p "$B" "$OUT" "$B/home" "$B/home-first-day"
CF="-fobjc-arc -Wall -mmacosx-version-min=13.0 -ISources"
clang $CF -Dmain=xx_main -c Sources/main.m -o "$B/main.o"
clang $CF -framework Cocoa -framework ServiceManagement -framework UserNotifications "$B/main.o" \
  Sources/Common.m Sources/Rules.m Sources/Trees.m Sources/Review.m Sources/Forest.m tools/render.m -o "$B/render"
echo $(( $(date +%s) - 3 * 86400 )) > "$B/home/watching-since"   # watching for three days: modes act
date +%s > "$B/home-first-day/watching-since"                    # just started: the first-day state
WORKFOREST_HOME="$PWD/$B/home" "$B/render" "$OUT"
mkdir -p "$OUT/first-day"; WORKFOREST_HOME="$PWD/$B/home-first-day" "$B/render" "$OUT/first-day"

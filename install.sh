#!/bin/sh
# WorkForest installer: builds from source with clang (no Gatekeeper quarantine),
# installs to ~/Applications plus a `workforest` CLI in ~/.local/bin, launches, and verifies.
#
#   curl -fsSL https://raw.githubusercontent.com/FRIKKern/workforest/main/install.sh | sh
#
# Options (env vars, so they work through a pipe):
#   WORKFOREST_REF=v0.1.0     git ref to install (default: main)
#   WORKFOREST_NO_LAUNCH=1    build and install only
#   WORKFOREST_LOGIN=1        also register Launch at Login
set -eu

REPO="https://github.com/FRIKKern/workforest"
REF="${WORKFOREST_REF:-main}"
DEST="$HOME/Applications/WorkForest.app"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "WorkForest is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || die "macOS 13 or newer required (found $(sw_vers -productVersion))."

if ! xcode-select -p >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
  say "Command Line Tools are missing. Opening Apple's installer; re-run this script when it finishes."
  xcode-select --install 2>/dev/null || true
  die "Command Line Tools not installed yet."
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say "Fetching $REPO@$REF"
curl -fsSL "$REPO/archive/$REF.tar.gz" | tar -xz -C "$TMP" --strip-components=1

say "Building (clang, universal)"
(cd "$TMP" && sh build.sh --no-install >/dev/null)

if pgrep -x WorkForest >/dev/null 2>&1; then
  say "Stopping running WorkForest"
  open "workforest://quit" 2>/dev/null || pkill -x WorkForest || true
  sleep 1
fi

say "Installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$TMP/build/WorkForest.app" "$DEST"

[ "${WORKFOREST_NO_LAUNCH:-0}" = "1" ] && { say "Installed. Launch with: open $DEST"; exit 0; }

say "Launching"
open "$DEST"
sleep 2
[ "${WORKFOREST_LOGIN:-0}" = "1" ] && { open "workforest://login-on"; say "Registered Launch at Login (macOS may ask you to approve it once)."; }

sleep 1
mkdir -p "$HOME/.local/bin"; ln -sf "$DEST/Contents/MacOS/WorkForest" "$HOME/.local/bin/workforest"
if pgrep -x WorkForest >/dev/null 2>&1; then
  say "Verified: WorkForest is running. Look for the tree icon and a count in your menu bar. CLI: ~/.local/bin/workforest list"
else
  say "Installed. Launch with: open $DEST"
fi

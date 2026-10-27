#!/bin/sh
# Removes WorkForest completely: app, CLI link, preferences, rules, review and removal records, saved files, login item.
#   curl -fsSL https://raw.githubusercontent.com/FRIKKern/workforest/main/uninstall.sh | sh
set -u
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
if pgrep -x WorkForest >/dev/null 2>&1; then
  say "Stopping WorkForest"; open "workforest://login-off" 2>/dev/null; sleep 1; open "workforest://quit" 2>/dev/null || pkill -x WorkForest; sleep 1
fi
SUP="$HOME/Library/Application Support/WorkForest"
if grep -q '"id"' "$SUP/removed.json" 2>/dev/null; then   # restore records and the .env files saved from removed worktrees
  KEEP="$HOME/WorkForest-removed-$(date +%Y%m%d)"; mkdir -p "$KEEP"
  mv "$SUP/removed.json" "$KEEP/" 2>/dev/null; mv "$SUP/removed" "$KEEP/" 2>/dev/null
  say "Kept the records and saved files of removed worktrees in $KEEP"
fi
rm -rf "$HOME/Applications/WorkForest.app" "/Applications/WorkForest.app" "$HOME/.local/bin/workforest" "$HOME/Library/Application Support/WorkForest" 2>/dev/null
defaults delete no.guerrilla.workforest >/dev/null 2>&1
say "WorkForest removed."

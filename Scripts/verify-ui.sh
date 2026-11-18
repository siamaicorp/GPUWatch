#!/bin/bash
#
# Visual QA.
#
# 1. Renders every screen from the real view types into dist/screenshots/.
# 2. Starts the app with demo data and prints where its menu bar item and
#    popover are, so they can be captured or looked at.
#
# Runs against a throwaway store, so it never touches your configuration.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SHOTS="$ROOT/dist/screenshots"

echo "==> Rendering screens to $SHOTS"
swift run -c release GPUWatchSnapshot "$SHOTS" 2>&1 | sed 's/^/    /'

echo
echo "==> Building the app"
"$ROOT/Scripts/build-app.sh" >/dev/null
APP="$ROOT/dist/GPUWatch.app/Contents/MacOS/GPUWatch"

echo
echo "==> Menu bar item and popover position"
"$APP" --diagnose 2>&1 | sed 's/^/    /'

cat <<'NOTE'

To look at the real popover:
    1. run:  dist/GPUWatch.app --show-popover
    2. it opens over the demo fleet and stays open for 25 seconds

The menu bar item is placed on whichever display currently owns the menu bar,
which on a multi-display setup is not necessarily the main one. `--diagnose`
prints its coordinates so you can tell "installed but elsewhere" apart from
"not installed".
NOTE

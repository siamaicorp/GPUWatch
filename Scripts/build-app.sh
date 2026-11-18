#!/bin/bash
#
# Builds GPUWatch.app.
#
# Repeatable and self-contained: run it as often as you like, it always produces
# the same layout under dist/.
#
# Signing: by default this ad-hoc signs with `--sign -`, which is what a local
# build on this machine needs. It does NOT notarise, and it does NOT touch
# Gatekeeper or any security setting on the machine. For distribution, sign with
# a Developer ID identity and notarise — see README.
#
#   SIGN_IDENTITY="Developer ID Application: …" ./Scripts/build-app.sh
#
# Architecture: by default this builds for the machine it runs on. Set
# UNIVERSAL=1 to build a universal binary covering both Apple Silicon and Intel,
# which is what a published release should use — an arm64-only download simply
# will not open on an Intel Mac.
#
#   UNIVERSAL=1 ./Scripts/build-app.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="GPUWatch"
BUNDLE_ID="com.siamai.gpuwatch"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Bash 3.2 on macOS treats an empty array expansion as an unbound variable under
# `set -u`, hence the `${arr[@]+...}` guard rather than a bare "${arr[@]}".
ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  echo "==> Universal build: arm64 + x86_64"
fi

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product "$APP_NAME"

BIN="$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product "$APP_NAME" --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN" ]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The SIAM.AI brand mark and the app icon.
if [ -f "$ROOT/Packaging/Brand/AppIcon.icns" ]; then
  cp "$ROOT/Packaging/Brand/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    warning: Packaging/Brand/AppIcon.icns is missing; the app will use the generic icon"
fi

# SwiftPM puts the target's resources in a bundle next to the binary. It has to
# travel with the app or the brand mark and its fallback disappear.
BUNDLE="$(dirname "$BIN")/${APP_NAME}_GPUWatchUI.bundle"
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
else
  echo "    warning: resource bundle not found at $BUNDLE"
fi

# A version stamp so a build can be identified later without guessing.
{
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "configuration=$CONFIGURATION"
  echo "swift=$(swift --version 2>/dev/null | head -1)"
} > "$APP/Contents/Resources/build-info.txt"

# Clear extended attributes on the copy we just made, so nothing inherited from
# a build artifact interferes with signing. This is not a Gatekeeper change:
# the quarantine flag is only set on files that arrived from the network, and
# this file was built here.
xattr -c "$APP" 2>/dev/null || true

echo "==> Signing with identity: $SIGN_IDENTITY"
codesign --force --options runtime --timestamp=none \
  --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  "$APP" 2>&1 | sed 's/^/    /' || {
    echo "    ad-hoc signing with hardened runtime failed; retrying without it"
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  }

echo "==> Verifying"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo "    architecture: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)" 

echo
echo "Built $APP"
echo "Run it with:  open \"$APP\""
echo "The app appears in the menu bar only — there is no Dock icon."

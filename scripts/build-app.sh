#!/usr/bin/env bash
# Builds build/Huaci.app from the Swift package.
#
# Environment:
#   UNIVERSAL=1        Build for both arm64 and x86_64.
#   SIGN_IDENTITY      "Developer ID Application: …" for distribution; ad-hoc when unset.
#   NOTARY_PROFILE     notarytool keychain profile; notarizes and staples when set (needs SIGN_IDENTITY).
#   VERSION            CFBundleShortVersionString (default 0.0.5).
#   ANTIGRAVITY_CLIENT_ID, ANTIGRAVITY_CLIENT_SECRET
#                      Antigravity OAuth client, written into Info.plist. Also read
#                      from the gitignored secrets.env; Antigravity login is
#                      unavailable when unset.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
if [[ -f "$ROOT/secrets.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/secrets.env"
  set +a
fi
APP="$ROOT/build/Huaci.app"
VERSION="${VERSION:-0.0.5}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Huaci" "$APP/Contents/MacOS/Huaci"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>Huaci</string>
  <key>CFBundleIdentifier</key><string>app.huaci.Huaci</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>划词</string>
  <key>CFBundleDisplayName</key><string>划词</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ -n "${ANTIGRAVITY_CLIENT_ID:-}" && -n "${ANTIGRAVITY_CLIENT_SECRET:-}" ]]; then
  plutil -insert HuaciAntigravityClientID -string "$ANTIGRAVITY_CLIENT_ID" "$APP/Contents/Info.plist"
  plutil -insert HuaciAntigravityClientSecret -string "$ANTIGRAVITY_CLIENT_SECRET" "$APP/Contents/Info.plist"
else
  echo "warning: ANTIGRAVITY_CLIENT_ID/ANTIGRAVITY_CLIENT_SECRET not set; Antigravity login will be unavailable" >&2
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  # Ad-hoc signature: fine for local use, but Accessibility permission must be
  # re-granted after each rebuild because the signature changes.
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE requires SIGN_IDENTITY" >&2; exit 1; }
  ZIP="$ROOT/build/Huaci-${VERSION}.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Notarized archive: $ZIP"
fi

echo "Built $APP"

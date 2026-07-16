#!/bin/bash
# Builds gjPiP.app. TCC (Screen Recording / Accessibility) only grants
# permission to a signed app bundle, so a bare SwiftPM binary is not enough.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="build/gjPiP.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/gjPiP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/gjPiP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>gjPiP</string>
	<key>CFBundleIdentifier</key><string>co.gridworld.gjPiP</string>
	<key>CFBundleName</key><string>gjPiP</string>
	<key>CFBundleDisplayName</key><string>gjPiP</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSScreenCaptureUsageDescription</key>
	<string>選択したディスプレイの内容を PiP ウィンドウに表示するために画面収録を使用します。</string>
</dict>
</plist>
PLIST

# Signing with the certificate keeps the designated requirement stable across
# rebuilds, so TCC doesn't treat each build as a new app and drop its Screen
# Recording / Accessibility grants. Ad-hoc still works, it just re-prompts every
# time — run ./make-signing-cert.sh once to avoid that.
CERT_NAME="gjPiP Self-Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    IDENTITY="$CERT_NAME"
else
    IDENTITY="-"
    echo "warning: '$CERT_NAME' not found, signing ad-hoc — permissions will"
    echo "         reset on every rebuild. Run ./make-signing-cert.sh to fix."
fi
codesign --force --sign "$IDENTITY" --identifier co.gridworld.gjPiP "$APP"

echo "built: $APP (signed by: $IDENTITY)"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

APP="$ROOT/GrizzyBot.app"
BIN="$ROOT/.build/release/GrizzyBot"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>GrizzyBot</string>
	<key>CFBundleIdentifier</key>
	<string>com.grizzybot.app</string>
	<key>CFBundleName</key>
	<string>GrizzyBot</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/GrizzyBot"
chmod +x "$APP/Contents/MacOS/GrizzyBot"

# SPM statically links GrizzyBotCore — no Frameworks embed. Ad-hoc sign the bundle.
codesign --force --sign - --timestamp=none \
  --entitlements "$ROOT/Sources/GrizzyBot/GrizzyBot.entitlements" \
  --options runtime \
  "$APP/Contents/MacOS/GrizzyBot"
codesign --force --sign - --timestamp=none \
  --entitlements "$ROOT/Sources/GrizzyBot/GrizzyBot.entitlements" \
  --options runtime \
  "$APP"

echo "Built $APP"
open "$APP"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product GrizzyBot --product GrizzyBotRoutineAgent

APP="$ROOT/GrizzyBot.app"
BIN="$ROOT/.build/release/GrizzyBot"
AGENT_BIN="$ROOT/.build/release/GrizzyBotRoutineAgent"

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
	<string>2</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1</string>
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
	<key>NSMicrophoneUsageDescription</key>
	<string>GrizzyBot uses the microphone so you can dictate messages to a bot.</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>GrizzyBot uses on-device speech recognition to turn dictation into chat text.</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>GrizzyBot agents can open URLs and control this Mac when a bot’s computer mode is This Mac.</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>GrizzyBot captures the screen so a bot can see this Mac when computer mode is This Mac.</string>
	<key>NSAccessibilityUsageDescription</key>
	<string>GrizzyBot uses Accessibility so a bot can see and control this Mac when computer mode is This Mac.</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>GrizzyBot talks to local and LAN model servers (Ollama, LM Studio, vMLX, oMLX) on this network.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_http._tcp</string>
	</array>
	<key>SentryDSN</key>
	<string></string>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/GrizzyBot"
chmod +x "$APP/Contents/MacOS/GrizzyBot"

FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
embed_framework() {
  local name="$1"
  local found
  found="$(find "$ROOT/.build" -name "${name}.framework" | head -1 || true)"
  if [[ -n "$found" && -d "$found" ]]; then
    rm -rf "$FRAMEWORKS/${name}.framework"
    cp -R "$found" "$FRAMEWORKS/${name}.framework"
    codesign --force --sign "${CODE_SIGN_IDENTITY}" ${CODE_SIGN_TIMESTAMP} --deep "$FRAMEWORKS/${name}.framework"
  fi
}

if [[ -n "${GRIZZYBOT_DEVELOPMENT_TEAM:-}" && "${GRIZZYBOT_DEVELOPMENT_TEAM}" != "YOURTEAMID" ]]; then
  CODE_SIGN_IDENTITY="${GRIZZYBOT_CODE_SIGN_IDENTITY:-Developer ID Application}"
  CODE_SIGN_TIMESTAMP="--timestamp"
  ENTITLEMENTS="$ROOT/Sources/GrizzyBot/GrizzyBot.Release.entitlements"
else
  CODE_SIGN_IDENTITY="-"
  CODE_SIGN_TIMESTAMP="--timestamp=none"
  ENTITLEMENTS="$ROOT/Sources/GrizzyBot/GrizzyBot.entitlements"
fi

embed_framework Sentry

ICON="$ROOT/Sources/GrizzyBot/Resources/AppIcon.icns"
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
fi

codesign --force --sign "$CODE_SIGN_IDENTITY" $CODE_SIGN_TIMESTAMP \
  --entitlements "$ENTITLEMENTS" \
  --options runtime \
  "$APP/Contents/MacOS/GrizzyBot"
codesign --force --sign "$CODE_SIGN_IDENTITY" $CODE_SIGN_TIMESTAMP \
  --entitlements "$ENTITLEMENTS" \
  --options runtime \
  "$APP"

if [[ -f "$AGENT_BIN" ]]; then
  "$ROOT/Scripts/embed-routine-agent.sh" "$APP" "$AGENT_BIN"
  codesign --force --sign "$CODE_SIGN_IDENTITY" $CODE_SIGN_TIMESTAMP \
    --options runtime \
    "$APP/Contents/MacOS/GrizzyBotRoutineAgent"
  codesign --force --sign "$CODE_SIGN_IDENTITY" $CODE_SIGN_TIMESTAMP \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$APP"
fi

echo "Built $APP (signed with $CODE_SIGN_IDENTITY)"
open "$APP"

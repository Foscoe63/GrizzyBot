#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Build with Xcode's toolchain, not whatever `swift` happens to be on PATH.
# An open-source toolchain (e.g. swiftly) has no CryptoKit, so GoogleOAuth.swift
# fails to compile — and SwiftPM has been observed to link around the missing
# object without an error, producing an app that launches with the Google
# sign-in feature silently absent.
XCODE_TOOLCHAIN="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/Toolchains/XcodeDefault.xctoolchain/usr/bin"
if [[ -x "$XCODE_TOOLCHAIN/swift" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  export PATH="$XCODE_TOOLCHAIN:$PATH"
else
  echo "error: Xcode's Swift toolchain not found at $XCODE_TOOLCHAIN" >&2
  echo "       Install Xcode, or set DEVELOPER_DIR to its Developer directory." >&2
  exit 1
fi

# One product per invocation: SwiftPM keeps only the last `--product` flag, so
# a combined call silently builds just the routine agent and leaves the app
# binary missing (or stale from an earlier run).
swift build -c release --product GrizzyBot
swift build -c release --product GrizzyBotRoutineAgent

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

# MLX's Metal shaders. Without them every Local MLX model load dies with
# "Failed to load the default metallib". MLX walks the loaded bundles for its
# SwiftPM resource bundle, so Contents/Resources is both the place it finds and
# the only place codesign accepts — a loose .metallib in Contents/MacOS is
# rejected as an unsigned subcomponent.
embed_mlx_metallib() {
  local bundle
  bundle="$(find "$ROOT/.build" -name 'mlx-swift_Cmlx.bundle' -type d | head -1 || true)"
  if [[ -z "$bundle" ]]; then
    echo "error: mlx-swift_Cmlx.bundle not found; Local MLX models would not load" >&2
    exit 1
  fi
  rm -rf "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
  cp -R "$bundle" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"

  if [[ ! -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
    echo "error: default.metallib missing from the embedded MLX bundle" >&2
    exit 1
  fi
}

embed_mlx_metallib

# Vendored browser runtimes for the artifact frame. SwiftPM drops them in its
# own resource bundle, but ArtifactSchemeHandler resolves them from the app's
# Contents/Resources — which is also exactly where the Xcode build's folder
# reference puts them, so both builds agree. Copied from the source tree rather
# than the build output so the layout cannot drift.
embed_artifact_runtime() {
  local src="$ROOT/Sources/GrizzyBot/Resources/ArtifactRuntime"
  if [[ ! -d "$src" ]]; then
    echo "error: ArtifactRuntime resources not found; HTML, SVG, diagram and React artifacts would render blank" >&2
    exit 1
  fi
  rm -rf "$APP/Contents/Resources/ArtifactRuntime"
  cp -R "$src" "$APP/Contents/Resources/ArtifactRuntime"

  for required in react.js react-dom.js babel.js mermaid.js tailwind.js; do
    if [[ ! -s "$APP/Contents/Resources/ArtifactRuntime/$required" ]]; then
      echo "error: $required missing from the embedded artifact runtime" >&2
      exit 1
    fi
  done
}

embed_artifact_runtime

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

#!/usr/bin/env bash
# Sign a GrizzyBot.dmg with Sparkle EdDSA and insert it into appcast.xml.
# Usage:
#   SPARKLE_PRIVATE_KEY=... ./Scripts/publish-update.sh path/to/GrizzyBot.dmg
# Optional env: SHORT_VERSION, BUILD_VERSION, NOTES_HTML, ENCLOSURE_URL, APPCAST
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:?Usage: $0 path/to/GrizzyBot.dmg}"
APPCAST="${APPCAST:-$ROOT/appcast.xml}"
SHORT_VERSION="${SHORT_VERSION:-}"
BUILD_VERSION="${BUILD_VERSION:-}"
NOTES_HTML="${NOTES_HTML:-<p>GrizzyBot update</p>}"

if [[ ! -f "$DMG" ]]; then
  echo "DMG not found: $DMG" >&2
  exit 1
fi

KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$ROOT/Scripts/sparkle_eddsa_private.key}"
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" && -f "$KEY_FILE" ]]; then
  SPARKLE_PRIVATE_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
fi
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "Set SPARKLE_PRIVATE_KEY or put the EdDSA seed in Scripts/sparkle_eddsa_private.key" >&2
  exit 1
fi

SIGN_UPDATE="${SIGN_UPDATE:-}"
if [[ -z "$SIGN_UPDATE" ]]; then
  SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" "$ROOT/.build" -name sign_update -type f 2>/dev/null | head -1 || true)"
fi
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
  echo "sign_update not found. Build GrizzyBot with Sparkle first." >&2
  exit 1
fi

if [[ -z "$SHORT_VERSION" || -z "$BUILD_VERSION" ]]; then
  PLIST="$ROOT/Sources/GrizzyBot/Info.plist"
  SHORT_VERSION="${SHORT_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
  BUILD_VERSION="${BUILD_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")}"
fi

ENCLOSURE_URL="${ENCLOSURE_URL:-https://github.com/Foscoe63/GrizzyBot/releases/download/v${SHORT_VERSION}/GrizzyBot.dmg}"
PUBDATE="$(date -R)"
LENGTH="$(stat -f%z "$DMG" 2>/dev/null || stat -c%s "$DMG")"

# Sparkle 2 sign_update: -f keyfile or SPARKLE_PRIVATE_KEY_FILE. The gitignored
# file is a raw EdDSA seed; generate_keys format also works.
SIGN_OUT="$("$SIGN_UPDATE" "$DMG" -f "$KEY_FILE" 2>/dev/null || SPARKLE_PRIVATE_KEY="$SPARKLE_PRIVATE_KEY" "$SIGN_UPDATE" "$DMG")"
ED_SIG="$(printf '%s\n' "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -1)"
if [[ -z "$ED_SIG" ]]; then
  echo "sign_update did not print sparkle:edSignature. Output:" >&2
  echo "$SIGN_OUT" >&2
  exit 1
fi

python3 - "$APPCAST" "$SHORT_VERSION" "$BUILD_VERSION" "$PUBDATE" "$ENCLOSURE_URL" "$ED_SIG" "$LENGTH" "$NOTES_HTML" <<'PY'
import re, sys
path, short, build, pubdate, url, sig, length, notes = sys.argv[1:]
xml = open(path, encoding="utf-8").read()
item = f'''
    <item>
      <title>Version {short}</title>
      <pubDate>{pubdate}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}"
                 type="application/octet-stream"
                 sparkle:edSignature="{sig}"
                 length="{length}" />
    </item>
'''
xml = re.sub(
    rf"<item>[\s\S]*?<sparkle:version>{re.escape(build)}</sparkle:version>[\s\S]*?</item>",
    "",
    xml,
)
if "<channel>" not in xml:
    sys.exit("appcast.xml is missing <channel>")
xml = xml.replace("<channel>", "<channel>" + item, 1)
open(path, "w", encoding="utf-8").write(xml)
print(f"Wrote {path} item {short} ({build}) length={length}")
PY

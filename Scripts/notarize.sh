#!/usr/bin/env bash
# Notarize a Developer ID-signed GrizzyBot.app or .dmg with notarytool.
# Requires Configs/Team.xcconfig (or GRIZZYBOT_DEVELOPMENT_TEAM) and an
# app-specific password in NOTARY_KEYCHAIN_PROFILE (default: GrizzyBot-notary).
#
#   ./Scripts/notarize.sh path/to/GrizzyBot.app
#   ./Scripts/notarize.sh path/to/GrizzyBot.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?Usage: $0 path/to/GrizzyBot.app|GrizzyBot.dmg}"
PROFILE="${NOTARY_KEYCHAIN_PROFILE:-GrizzyBot-notary}"

if [[ ! -e "$TARGET" ]]; then
  echo "Nothing at $TARGET" >&2
  exit 1
fi

TEAM="${GRIZZYBOT_DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" && -f "$ROOT/Configs/Team.xcconfig" ]]; then
  TEAM="$(sed -n 's/^GRIZZYBOT_DEVELOPMENT_TEAM *= *//p' "$ROOT/Configs/Team.xcconfig" | tr -d '[:space:]')"
fi
if [[ -z "$TEAM" || "$TEAM" == "YOURTEAMID" ]]; then
  echo "Set GRIZZYBOT_DEVELOPMENT_TEAM or copy Configs/Team.xcconfig.example → Configs/Team.xcconfig" >&2
  exit 1
fi

IDENTITY="${GRIZZYBOT_CODE_SIGN_IDENTITY:-Developer ID Application}"
ENTITLEMENTS="$ROOT/Sources/GrizzyBot/GrizzyBot.Release.entitlements"

if [[ -d "$TARGET" && "$TARGET" == *.app ]]; then
  codesign --force --sign "$IDENTITY" --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" "$TARGET"
fi

echo "Submitting $TARGET to Apple notary service (team $TEAM, profile $PROFILE)…"
xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$TARGET"
echo "Stapled $TARGET"
echo "Verify with: spctl --assess --type execute -vv ${TARGET%.dmg}"

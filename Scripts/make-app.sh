#!/usr/bin/env bash
# Build GrizzyBot.app exactly the way a release is built.
#
# This used to assemble the bundle itself from `swift build` output — its own
# Info.plist, its own framework and resource embedding, its own signing. That
# drifted from what actually ships: the SPM path produced an arm64-only binary
# with no Assets.car and none of the SwiftPM resource bundles, so an app built
# here would not launch on an Intel Mac while the release did. Two paths cannot
# drift if there is only one, so this runs the same xcodegen + xcodebuild steps
# as .github/workflows/release.yml and then checks what came out.
#
#   ./Scripts/make-app.sh
#
# Signing follows Configs/Release.xcconfig: ad-hoc unless Configs/Team.xcconfig
# (or GRIZZYBOT_DEVELOPMENT_TEAM) names a team, in which case Developer ID is
# used and Scripts/notarize.sh can take it from there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# xcodebuild must come from a real Xcode. An open-source toolchain on PATH
# (swiftly, CommandLineTools) cannot build this app: no CryptoKit for
# GoogleOAuth.swift, no actool for the asset catalog.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "error: no xcodebuild at $DEVELOPER_DIR" >&2
  echo "       Install Xcode, or set DEVELOPER_DIR to its Developer directory." >&2
  exit 1
fi

read_setting() {
  local key="$1" value
  value="$(sed -n "s/^[[:space:]]*${key}:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" project.yml | head -1)"
  if [[ -z "$value" ]]; then
    echo "error: ${key} not found in project.yml" >&2
    exit 1
  fi
  printf '%s' "$value"
}
MARKETING_VERSION="$(read_setting MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(read_setting CURRENT_PROJECT_VERSION)"
echo "Building GrizzyBot $MARKETING_VERSION (build $CURRENT_PROJECT_VERSION)"

# project.yml is the source; the .xcodeproj is generated from it. Regenerating
# is what keeps a file added to one build system from being missing in the other.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
elif [[ ! -d "$ROOT/GrizzyBot.xcodeproj" ]]; then
  echo "error: no GrizzyBot.xcodeproj and xcodegen is not installed (brew install xcodegen)" >&2
  exit 1
else
  echo "warning: xcodegen not installed — building the existing project, which may be stale" >&2
fi

DERIVED="$ROOT/.build/xcode"
# Expanded below as ${SIGNING[@]+"${SIGNING[@]}"}: under `set -u`, macOS's stock
# bash 3.2 treats an empty array as an unbound variable and aborts the build.
SIGNING=()
if [[ -n "${GRIZZYBOT_DEVELOPMENT_TEAM:-}" && "${GRIZZYBOT_DEVELOPMENT_TEAM}" != "YOURTEAMID" ]]; then
  echo "Signing with Developer ID (team ${GRIZZYBOT_DEVELOPMENT_TEAM})"
  SIGNING=(
    CODE_SIGN_IDENTITY="${GRIZZYBOT_CODE_SIGN_IDENTITY:-Developer ID Application}"
    DEVELOPMENT_TEAM="${GRIZZYBOT_DEVELOPMENT_TEAM}"
  )
fi

xcodebuild \
  -project GrizzyBot.xcodeproj \
  -scheme GrizzyBot \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation -skipPackagePluginValidation \
  ${SIGNING[@]+"${SIGNING[@]}"} \
  build

PRODUCT="$DERIVED/Build/Products/Release/GrizzyBot.app"
if [[ ! -d "$PRODUCT" ]]; then
  echo "error: no app bundle at $PRODUCT" >&2
  exit 1
fi

APP="$ROOT/GrizzyBot.app"
rm -rf "$APP"
# ditto rather than cp -R: it preserves the signature's extended attributes.
ditto "$PRODUCT" "$APP"

# Everything below is a check, not a build step. Each one stands for a way this
# bundle has actually shipped broken before.
fail() { echo "error: $1" >&2; exit 1; }

got_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
got_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$got_version" == "$MARKETING_VERSION" ]] \
  || fail "bundle says version $got_version, project.yml says $MARKETING_VERSION"
[[ "$got_build" == "$CURRENT_PROJECT_VERSION" ]] \
  || fail "bundle says build $got_build, project.yml says $CURRENT_PROJECT_VERSION"

# An arm64-only bundle launches fine here and fails on every Intel Mac.
archs="$(lipo -archs "$APP/Contents/MacOS/GrizzyBot")"
for required in x86_64 arm64; do
  [[ "$archs" == *"$required"* ]] || fail "binary is missing $required (has: $archs)"
done

# MLX's Metal shaders. Without them every Local MLX model load dies with
# "Failed to load the default metallib".
[[ -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] \
  || fail "default.metallib missing — Local MLX models would not load"

# Vendored browser runtimes for the artifact frame, resolved from
# Contents/Resources by ArtifactSchemeHandler.
for runtime in react.js react-dom.js babel.js mermaid.js tailwind.js; do
  [[ -s "$APP/Contents/Resources/ArtifactRuntime/$runtime" ]] \
    || fail "$runtime missing — HTML, SVG, diagram and React artifacts would render blank"
done

[[ -x "$APP/Contents/MacOS/GrizzyBotRoutineAgent" ]] \
  || fail "the routine agent is not embedded — background routines would not run"

codesign --verify --strict "$APP" || fail "the bundle does not pass codesign --verify"

echo "Built $APP"
echo "  version   $got_version (build $got_build)"
echo "  archs     $archs"
echo "  signature $(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p')"

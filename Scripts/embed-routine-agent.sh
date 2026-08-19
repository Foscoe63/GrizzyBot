#!/usr/bin/env bash
# Embed the routine agent + LaunchAgent plist into GrizzyBot.app after build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/GrizzyBot.app}"
PLIST_SRC="$ROOT/Sources/GrizzyBotRoutineAgent/com.grizzybot.routine-agent.plist"

if [[ ! -d "$APP" ]]; then
  echo "App not found: $APP" >&2
  exit 1
fi

resolve_agent_bin() {
  if [[ -n "${1:-}" && -f "$1" ]]; then
    echo "$1"
    return 0
  fi
  local candidate
  for candidate in \
    "${BUILT_PRODUCTS_DIR:-}/GrizzyBotRoutineAgent" \
    "${TARGET_BUILD_DIR:-}/GrizzyBotRoutineAgent" \
    "$ROOT/.build/debug/GrizzyBotRoutineAgent" \
    "$ROOT/.build/release/GrizzyBotRoutineAgent"
  do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

AGENT_BIN="$(resolve_agent_bin "${2:-}")" || {
  echo "Routine agent binary not found (build GrizzyBotRoutineAgent target first)" >&2
  exit 1
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
cp "$AGENT_BIN" "$APP/Contents/MacOS/GrizzyBotRoutineAgent"
chmod +x "$APP/Contents/MacOS/GrizzyBotRoutineAgent"
cp "$PLIST_SRC" "$APP/Contents/Library/LaunchAgents/com.grizzybot.routine-agent.plist"
echo "Embedded GrizzyBotRoutineAgent in $APP"

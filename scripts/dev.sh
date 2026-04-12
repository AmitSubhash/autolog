#!/usr/bin/env bash
# dev.sh — Build and run AutoLog with live log streaming in a split view.
#
# Usage:
#   ./scripts/dev.sh          # build + run + stream logs
#   ./scripts/dev.sh --release # build release + run
#   ./scripts/dev.sh --logs-only # just stream logs (app already running)

set -euo pipefail

PRODUCT="ContextD"
SUBSYSTEM="com.autolog.app"
BUILD_DIR=".build"
APP_BUNDLE="${BUILD_DIR}/AutoLog.app"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down...${RESET}"
    # Kill background jobs
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    echo -e "${GREEN}Done.${RESET}"
}
trap cleanup EXIT INT TERM

case "${1:-}" in
    --logs-only)
        echo -e "${CYAN}Streaming logs for ${SUBSYSTEM}...${RESET}"
        log stream --predicate "subsystem == \"${SUBSYSTEM}\"" --style compact
        exit 0
        ;;
    --release)
        CONFIG="release"
        ;;
    *)
        CONFIG="debug"
        ;;
esac

# Build
echo -e "${CYAN}Building (${CONFIG})...${RESET}"
if ! swift build -c "${CONFIG}" 2>&1; then
    echo -e "${RED}Build failed!${RESET}"
    exit 1
fi
echo -e "${GREEN}Build succeeded.${RESET}"
echo ""

# Create/update app bundle
echo -e "${CYAN}Creating app bundle...${RESET}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/${CONFIG}/${PRODUCT}" "${APP_BUNDLE}/Contents/MacOS/${PRODUCT}"
./scripts/gen-info-plist.sh > "${APP_BUNDLE}/Contents/Info.plist"
if [ -f Resources/contextd.icns ]; then
    cp Resources/contextd.icns "${APP_BUNDLE}/Contents/Resources/autolog.icns"
fi
if [ -f Resources/autolog-launch-agent.sh ]; then
    cp Resources/autolog-launch-agent.sh "${APP_BUNDLE}/Contents/Resources/autolog-launch-agent.sh"
    chmod 755 "${APP_BUNDLE}/Contents/Resources/autolog-launch-agent.sh"
fi

# Check if the app is already running
if pgrep -f "/Applications/AutoLog.app/Contents/MacOS/${PRODUCT}|${APP_BUNDLE}/Contents/MacOS/${PRODUCT}" > /dev/null 2>&1; then
    echo -e "${YELLOW}AutoLog is already running. Killing previous instance...${RESET}"
    pkill -f "${PRODUCT}" 2>/dev/null || true
    sleep 1
fi

# Start log streaming in background
echo -e "${CYAN}Starting log stream...${RESET}"
log stream --predicate "subsystem == \"${SUBSYSTEM}\"" --style compact &
LOG_PID=$!
sleep 0.5

# Run the app
echo -e "${CYAN}Starting ${APP_BUNDLE}...${RESET}"
echo -e "${YELLOW}Press Ctrl+C to stop log streaming. Quit the app separately when done.${RESET}"
echo "────────────────────────────────────────"
open -na "${APP_BUNDLE}"

wait "${LOG_PID}"

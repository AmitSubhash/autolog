#!/bin/bash
# Install all launchd agents for autolog.
# Copies plists to ~/Library/LaunchAgents and loads them so autolog
# services auto-start on login.
#
# Usage:
#   ./scripts/install-launchd.sh          # install all agents
#   ./scripts/install-launchd.sh --remove # unload and remove all agents

set -euo pipefail

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
SRC_DIR="$(cd "$(dirname "$0")/../launchd" && pwd)"
GUI_DOMAIN="gui/$(id -u)"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
OBSOLETE_LABELS=(
    "com.contextd.obsidian-sync"
    "com.contextd.daily-pattern-report"
    "com.contextd.weekly-pattern-rollup"
)

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Ensure target directory exists
mkdir -p "$LAUNCHD_DIR"

plist_label() {
    "$PLIST_BUDDY" -c "Print :Label" "$1"
}

bootout_job() {
    local plist_path="$1"
    local label="$2"
    launchctl bootout "$GUI_DOMAIN" "$plist_path" 2>/dev/null || \
        launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
}

remove_obsolete_jobs() {
    for label in "${OBSOLETE_LABELS[@]}"; do
        local target="$LAUNCHD_DIR/$label.plist"
        bootout_job "$target" "$label"
        launchctl disable "$GUI_DOMAIN/$label" 2>/dev/null || true
        rm -f "$target"
        echo -e "  ${YELLOW}Removed obsolete agent: $label${RESET}"
    done
}

if [ "${1:-}" = "--remove" ]; then
    echo -e "${CYAN}Removing autolog launchd agents...${RESET}"
    remove_obsolete_jobs
    for plist in "$SRC_DIR"/*.plist; do
        [ -f "$plist" ] || continue
        name=$(basename "$plist")
        label=$(plist_label "$plist")
        if [ -f "$LAUNCHD_DIR/$name" ]; then
            bootout_job "$LAUNCHD_DIR/$name" "$label"
            rm -f "$LAUNCHD_DIR/$name"
            echo -e "  ${YELLOW}Removed: $name${RESET}"
        else
            echo -e "  (not installed: $name)"
        fi
    done
    echo -e "${GREEN}All autolog launchd agents removed.${RESET}"
    exit 0
fi

echo -e "${CYAN}Installing autolog launchd agents...${RESET}"
echo -e "  Source:  $SRC_DIR"
echo -e "  Target:  $LAUNCHD_DIR"
echo ""

remove_obsolete_jobs

installed=0
for plist in "$SRC_DIR"/*.plist; do
    [ -f "$plist" ] || continue
    name=$(basename "$plist")
    label=$(plist_label "$plist")
    target="$LAUNCHD_DIR/$name"

    # Stop the existing job before replacing the plist.
    bootout_job "$target" "$label"

    # Copy plist to LaunchAgents
    cp "$plist" "$target"

    # Load and start the agent using modern launchctl verbs.
    launchctl bootstrap "$GUI_DOMAIN" "$target"
    launchctl kickstart -k "$GUI_DOMAIN/$label" 2>/dev/null || true

    echo -e "  ${GREEN}Installed: $name${RESET}"
    installed=$((installed + 1))
done

if [ "$installed" -eq 0 ]; then
    echo -e "${RED}No plists found in $SRC_DIR${RESET}"
    exit 1
fi

echo ""
echo -e "${GREEN}All $installed launchd agents installed.${RESET}"
echo -e "autolog will auto-start on login."
echo ""
echo "To verify:"
echo "  launchctl print $GUI_DOMAIN/com.autolog.app"
echo ""
echo "To remove:"
echo "  ./scripts/install-launchd.sh --remove"

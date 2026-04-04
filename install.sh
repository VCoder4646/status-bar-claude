#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { printf "${GREEN}✓${NC} %s\n" "$1"; }
err()  { printf "${RED}✗${NC} %s\n" "$1" >&2; }
warn() { printf "${YELLOW}!${NC} %s\n" "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/statusline-command.sh"
DEST_DIR="$HOME/.claude"
DEST="$DEST_DIR/statusline-command.sh"
SETTINGS="$DEST_DIR/settings.json"

for dep in jq git bash; do
    if ! command -v "$dep" &>/dev/null; then
        err "Missing dependency: $dep"
        exit 1
    fi
done
ok "Dependencies found"

if [[ ! -f "$SOURCE" ]]; then
    err "statusline-command.sh not found in $SCRIPT_DIR"
    exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SOURCE" "$DEST"
chmod +x "$DEST"
ok "Installed $DEST"

if [[ ! -f "$SETTINGS" ]]; then
    echo '{}' > "$SETTINGS"
    warn "Created $SETTINGS"
fi

UPDATED="$(jq '. + {"statusLine": {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}}' "$SETTINGS")"
echo "$UPDATED" > "$SETTINGS"
ok "Updated $SETTINGS"

printf "\n${GREEN}Installation complete.${NC} Restart Claude Code to activate the status bar.\n"

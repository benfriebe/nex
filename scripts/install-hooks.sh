#!/bin/bash
set -euo pipefail

# Install nex CLI and configure Claude Code hooks.
# Run this after installing Nex.app.
#
# Safe to re-run: hook merging dedupes nex-managed commands (including
# absolute-path variants) and normalises their matchers — a re-run is
# the repair path `nex doctor` suggests for stale hook configs.
# NEX_INSTALL_DIR overrides where the nex symlink goes (default
# /usr/local/bin); the hooks invoke bare `nex`, so the directory must
# be on PATH in the shells Claude Code runs hooks from.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="/Applications/Nex.app"
BINARY="nex"
INSTALL_DIR="${NEX_INSTALL_DIR:-/usr/local/bin}"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Find the app bundle
if [ ! -d "$APP_PATH" ]; then
    # Try the current directory
    if [ -d "./Nex.app" ]; then
        APP_PATH="./Nex.app"
    else
        echo "Error: Nex.app not found in /Applications or current directory."
        echo "Usage: Run this script from the directory containing Nex.app, or install it to /Applications first."
        exit 1
    fi
fi

BINARY_SRC="$APP_PATH/Contents/Helpers/$BINARY"

if [ ! -f "$BINARY_SRC" ]; then
    echo "Error: $BINARY not found in app bundle at $BINARY_SRC"
    exit 1
fi

# Install nex into INSTALL_DIR (symlink so --version can find Info.plist)
echo "Installing $BINARY to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
ln -sf "$BINARY_SRC" "$INSTALL_DIR/$BINARY"
echo "  Installed $INSTALL_DIR/$BINARY -> $BINARY_SRC"
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        echo "  Warning: $INSTALL_DIR is not on this shell's PATH. The hooks run"
        echo "  bare 'nex' commands, so they will fail in shells that can't find it."
        ;;
esac

# Configure Claude Code hooks
echo "Configuring Claude Code hooks..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

HOOKS='{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "nex event stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "nex event notification"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "nex event session-start"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "nex event session-end"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "nex event start"
          }
        ]
      }
    ]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
    python3 "$SCRIPT_DIR/merge_hooks.py" "$SETTINGS_FILE" "$HOOKS"
    echo "  Merged hooks into existing $SETTINGS_FILE"
else
    echo "$HOOKS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
    echo "  Created $SETTINGS_FILE"
fi

# Install nex-agentic skill
SKILL_SRC="$APP_PATH/Contents/Resources/skills/nex-agentic"
SKILL_DEST="$HOME/.claude/skills/nex-agentic"

if [ -d "$SKILL_SRC" ]; then
    echo "Installing nex-agentic skill..."
    mkdir -p "$SKILL_DEST"
    cp "$SKILL_SRC/SKILL.md" "$SKILL_DEST/SKILL.md"
    echo "  Installed skill to $SKILL_DEST"
fi

echo ""
echo "Done! Nex hooks and skills are configured for Claude Code."
echo "Restart any running Claude Code sessions to pick up the new hooks."

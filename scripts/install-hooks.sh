#!/bin/bash
set -euo pipefail

# Install nex CLI and configure Claude Code hooks.
# Run this after installing Nex.app.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="/Applications/Nex.app"
BINARY="nex"
INSTALL_DIR="/usr/local/bin"
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

# Install nex to /usr/local/bin (symlink so --version can find Info.plist)
echo "Installing $BINARY to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
ln -sf "$BINARY_SRC" "$INSTALL_DIR/$BINARY"
echo "  Installed $INSTALL_DIR/$BINARY -> $BINARY_SRC"

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
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "nex event session-start"
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

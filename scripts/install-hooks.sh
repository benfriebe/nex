#!/bin/bash
set -euo pipefail

# Install nex CLI and configure Claude Code hooks.
# Run this after installing Nex.app.

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

# Install nex to /usr/local/bin
echo "Installing $BINARY to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp "$BINARY_SRC" "$INSTALL_DIR/$BINARY"
chmod 755 "$INSTALL_DIR/$BINARY"
echo "  Installed $INSTALL_DIR/$BINARY"

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
            "command": "nex --event stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "nex --event notification"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "nex --event session-start"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "nex --event start"
          }
        ]
      }
    ]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
    # Merge hooks into existing settings using python3 (ships with macOS)
    python3 -c "
import json, sys

with open('$SETTINGS_FILE', 'r') as f:
    settings = json.load(f)

new_hooks = json.loads('''$HOOKS''')['hooks']
settings.setdefault('hooks', {})
settings['hooks'].update(new_hooks)

with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"
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

echo ""
echo "Done! Nex hooks are configured for Claude Code."
echo "Restart any running Claude Code sessions to pick up the new hooks."

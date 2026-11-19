#!/bin/bash
# Installs the Ramble MCP server and connects it to Claude Code and the Claude desktop app.
# Safe to run again after editing ramble_mcp.py. It doesn't touch Ramble.app, so your permissions stay put.
set -euo pipefail
cd "$(dirname "$0")"

DEST_DIR="$HOME/Library/Application Support/Ramble/mcp"
DEST="$DEST_DIR/ramble_mcp.py"
PY=/usr/bin/python3
mkdir -p "$DEST_DIR"
cp ramble_mcp.py "$DEST"
chmod +x "$DEST"
echo "Installed $DEST"

# Claude Code: available in every project, for the default config and for any extra config
# folders named ~/.claude-* (e.g. separate work and personal logins via CLAUDE_CONFIG_DIR).
if command -v claude >/dev/null; then
  dirs=("")
  for d in "$HOME"/.claude-*/; do
    [ -f "$d.claude.json" ] && dirs+=("${d%/}")
  done
  cd "$HOME"  # claude may write config backups relative to the working directory
  for dir in "${dirs[@]}"; do
    echo "Claude Code config: ${dir:-default}"
    if [ -z "$dir" ]; then cc=(env -u CLAUDE_CONFIG_DIR claude); else cc=(env CLAUDE_CONFIG_DIR="$dir" claude); fi
    "${cc[@]}" mcp remove ramble --scope user >/dev/null 2>&1 || true
    "${cc[@]}" mcp add --scope user ramble -- "$PY" "$DEST"
  done
  cd - >/dev/null
else
  echo "Claude Code CLI not found; skipped. Later: claude mcp add --scope user ramble -- $PY \"$DEST\""
fi

# Claude desktop app (chat): add or update "ramble" under mcpServers, keeping everything else.
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if [ -d "$(dirname "$CONFIG")" ]; then
  [ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.before-ramble"
  "$PY" - "$CONFIG" "$PY" "$DEST" <<'EOF'
import json, os, sys
path, py, server = sys.argv[1:]
config = {}
if os.path.exists(path):
    with open(path) as f:
        config = json.load(f)
config.setdefault("mcpServers", {})["ramble"] = {"command": py, "args": [server]}
with open(path + ".tmp", "w") as f:
    json.dump(config, f, indent=2)
os.chmod(path + ".tmp", 0o600)
os.replace(path + ".tmp", path)
EOF
  echo "Added Ramble to the Claude desktop app's MCP servers (restart Claude to load it)."
fi

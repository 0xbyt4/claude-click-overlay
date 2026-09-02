#!/bin/sh
# Builds the overlay binary, runs the tests, and prints (or installs) the Claude Code hook config.
#
#   ./install.sh                Build, test, and print the hook JSON for manual installation.
#   ./install.sh --user         Also merge the hooks into ~/.claude/settings.json (backup kept).
#
# Requirements: macOS, Xcode Command Line Tools (swiftc), python3, Claude Code CLI with the
# built-in computer-use MCP server enabled via /mcp.
set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
BIN_DIR="$REPO_DIR/overlay/build"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This tool only works on macOS." >&2
    exit 1
fi
command -v swiftc >/dev/null 2>&1 || { echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found." >&2; exit 1; }

mkdir -p "$BIN_DIR"
echo "Building overlay binary..."
swiftc -O -o "$BIN_DIR/click-overlay" "$REPO_DIR"/overlay/*.swift
"$BIN_DIR/click-overlay" screen >/dev/null

echo "Running tests..."
python3 "$REPO_DIR/tools/test_sizing.py"
python3 "$REPO_DIR/tools/test_calibration.py"
python3 "$REPO_DIR/tools/test_hook_args.py"

HOOK="python3 \"$REPO_DIR/hooks/hook.py\""
HOOK_JSON=$(printf '%s' "$HOOK" | sed 's/"/\\"/g')
MATCHER_PRE='^mcp__computer-use__(left_click|right_click|middle_click|double_click|triple_click|left_click_drag|scroll|computer_batch)$'
MATCHER_POST='^mcp__computer-use__(left_click|right_click|middle_click|double_click|triple_click|left_click_drag|scroll|mouse_move|computer_batch)$'

if [ "${1:-}" = "--user" ]; then
    python3 - "$HOME/.claude/settings.json" "$HOOK" "$MATCHER_PRE" "$MATCHER_POST" <<'PY'
import json, os, shutil, sys, time
path, hook, matcher_pre, matcher_post = sys.argv[1:5]
settings = {}
if os.path.exists(path):
    shutil.copy(path, path + ".bak-" + time.strftime("%Y%m%d%H%M%S"))
    with open(path, encoding="utf-8") as handle:
        settings = json.load(handle)
hooks = settings.setdefault("hooks", {})
for event, matcher, mode in (("PreToolUse", matcher_pre, "pre"), ("PostToolUse", matcher_post, "post")):
    entries = hooks.setdefault(event, [])
    command = "%s %s" % (hook, mode)
    if any(h.get("command") == command for e in entries for h in e.get("hooks", [])):
        continue
    entries.append({"matcher": matcher, "hooks": [{"type": "command", "command": command, "timeout": 10}]})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
print("Hooks installed into", path)
PY
else
    cat <<JSON

Add this to ~/.claude/settings.json (or run ./install.sh --user to do it for you):

{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "$MATCHER_PRE",
        "hooks": [{ "type": "command", "command": "$HOOK_JSON pre", "timeout": 10 }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "$MATCHER_POST",
        "hooks": [{ "type": "command", "command": "$HOOK_JSON post", "timeout": 10 }]
      }
    ]
  }
}
JSON
fi
echo "Done."

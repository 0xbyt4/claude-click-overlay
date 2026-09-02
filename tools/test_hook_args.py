#!/usr/bin/env python3
"""Checks the overlay command line the pre hook builds for single actions and batches."""
import os
import sys
import tempfile

import json

STATE_DIR = tempfile.mkdtemp(prefix="click-overlay-test-")
os.environ["CLICK_OVERLAY_STATE_DIR"] = STATE_DIR
os.environ["CLICK_OVERLAY_CONFIG"] = os.path.join(STATE_DIR, "config.json")
os.environ["CLICK_OVERLAY_SOUND"] = "Pop"
os.environ["CLICK_OVERLAY_VOLUME"] = "0.4"
os.environ["CLICK_OVERLAY_PREVIEW_MS"] = "0"
os.environ["CLICK_OVERLAY_READY_TIMEOUT_MS"] = "0"
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks"))
import hook  # noqa: E402

SCREEN = {"width": 1470, "height": 956, "backingScale": 2.0, "name": "test"}
launched = []


class FakeProcess:
    pid = 4242
    returncode = None

    def poll(self):
        return None


def fake_run_overlay(args, timeout=2.0):
    assert args == ["screen"], args
    return SCREEN


def fake_popen(command, **kwargs):
    launched.append(command)
    return FakeProcess()


hook.run_overlay = fake_run_overlay
hook.subprocess.Popen = fake_popen
hook.OVERLAY_BIN = __file__  # any existing path satisfies the existence check
with open(os.environ["CLICK_OVERLAY_CONFIG"], "w", encoding="utf-8") as handle:
    json.dump({"typing": "fast"}, handle)

CASES = [
    (
        {"tool_name": "mcp__computer-use__left_click", "tool_input": {"coordinate": [456, 629]}},
        ["489,674,left click,click"],
    ),
    (
        {"tool_name": "mcp__computer-use__computer_batch", "tool_input": {"actions": [
            {"action": "left_click", "coordinate": [517, 578]},
            {"action": "type", "text": "2+2"},
            {"action": "scroll", "coordinate": [686, 446], "scroll_direction": "down", "scroll_amount": 3},
            {"action": "left_click_drag", "start_coordinate": [100, 100], "coordinate": [300, 400]},
            {"action": "mouse_move", "coordinate": [10, 10]},
        ]}},
        ["554,619,1 left click,click", "735,478,2 scroll,scroll", "107,107,3 drag,drag-start", "321,429,3 drop,drag-end"],
        [],
    ),
    (
        {"tool_name": "mcp__computer-use__computer_batch", "tool_input": {"actions": [{"action": "screenshot"}, {"action": "zoom", "region": [0, 0, 10, 10]}]}},
        None,
    ),
    (
        {"tool_name": "mcp__computer-use__type", "tool_input": {"text": "computer use test\nsecond line"}},
        None,
    ),
    (
        {"tool_name": "mcp__computer-use__computer_batch", "tool_input": {"actions": [
            {"action": "left_click", "coordinate": [456, 629]},
            {"action": "type", "text": "x" * 100},
            {"action": "key", "text": "Return", "repeat": 2},
            {"action": "hold_key", "text": "shift", "duration": 1.5},
        ]}},
        ["489,674,left click,click"],
        [],
    ),
]

failed = False
for case in CASES:
    payload, expected_markers = case[0], case[1]
    expected_banner = case[2] if len(case) > 2 else []
    launched.clear()
    hook.pre(payload)
    if expected_markers is None:
        ok = launched == []
        print("%s %s -> no overlay launched" % ("ok  " if ok else "FAIL", hook.action_name(payload["tool_name"])))
    else:
        command = launched[0] if launched else []
        markers = [command[i + 1] for i, token in enumerate(command) if token == "--marker"]
        banner = [command[i + 1] for i, token in enumerate(command) if token == "--banner"]
        options = dict(zip(command[2::2], command[3::2]))
        ok = (markers == expected_markers and banner == expected_banner and options.get("--sound") == "Pop"
              and options.get("--key-sound") == "none" and options.get("--scroll-sound") == "none"
              and options.get("--volume") == "0.4" and "--log" in command and options.get("--state-dir") == STATE_DIR)
        print("%s %s -> markers=%s banner=%s" % ("ok  " if ok else "FAIL", hook.action_name(payload["tool_name"]), markers, banner))
    failed |= not ok

import contextlib
import io


def run_pre(payload):
    """Run the pre hook and return (launched command, printed JSON or None)."""
    launched.clear()
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        hook.pre(payload)
    printed = json.loads(out.getvalue()) if out.getvalue().strip() else None
    return (launched[0] if launched else None), printed


def write_config(config):
    with open(os.environ["CLICK_OVERLAY_CONFIG"], "w", encoding="utf-8") as handle:
        json.dump(config, handle)


# The config file written by `click-overlay use` must win over the environment.
write_config({"typing": "fast", "sound": "melody:tetris", "key_sound": "typewriter", "scroll_sound": "bubble", "volume": 0.5})
command, _ = run_pre(CASES[0][0])
options = dict(zip(command[2::2], command[3::2]))
ok = options.get("--sound") == "melody:tetris" and options.get("--key-sound") == "typewriter" and options.get("--scroll-sound") == "bubble" and options.get("--volume") == "0.5"
print("%s config file overrides environment -> sound=%s key=%s scroll=%s volume=%s" % ("ok  " if ok else "FAIL", options.get("--sound"), options.get("--key-sound"), options.get("--scroll-sound"), options.get("--volume")))
failed |= not ok

# Banner on: keyboard actions get banner lines and share the numbering.
write_config({"typing": "fast", "typing_banner": "on"})
command, _ = run_pre(CASES[4][0])
banner = [command[i + 1] for i, token in enumerate(command) if token == "--banner"]
markers = [command[i + 1] for i, token in enumerate(command) if token == "--marker"]
ok = markers == ["489,674,1 left click,click"] and banner == ['2 typing "' + "x" * 69 + '\u2026" (100 chars)', "3 key Return x2", "4 hold shift for 1.5s"]
print("%s banner on -> markers=%s banner=%s" % ("ok  " if ok else "FAIL", markers, banner))
failed |= not ok

# Fast mode with an explicit key sound still launches a headless overlay for a standalone type.
write_config({"typing": "fast", "key_sound": "keyboard"})
command, printed = run_pre({"tool_name": "mcp__computer-use__type", "tool_input": {"text": "hello"}})
ok = command is not None and "--marker" not in command and "--banner" not in command and dict(zip(command[2::2], command[3::2])).get("--key-sound") == "keyboard" and printed is None
print("%s fast mode with key sound -> headless overlay, no output" % ("ok  " if ok else "FAIL"))
failed |= not ok

# Default mode is asmr: with no config at all, a standalone type is cut to its first character
# and the rest is stashed for the post hook.
os.remove(os.environ["CLICK_OVERLAY_CONFIG"])
ok = hook.sound_settings()["typing"] == "asmr" and hook.sound_settings()["key_sound"] == "mechkey"
print("%s defaults -> typing=asmr key_sound=mechkey" % ("ok  " if ok else "FAIL"))
failed |= not ok
payload = {"tool_name": "mcp__computer-use__type", "tool_use_id": "toolu_test_1", "tool_input": {"text": "Merhaba d\u00fcnya"}}
command, printed = run_pre(payload)
stash = hook.stash_path("toolu_test_1")
ok = (command is None and printed == {"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": {"text": "M"}}}
      and os.path.exists(stash) and json.load(open(stash, encoding="utf-8"))["remainder"] == "erhaba d\u00fcnya")
print("%s asmr type -> updatedInput first character, remainder stashed" % ("ok  " if ok else "FAIL"))
failed |= not ok

# ASMR mode: the post hook types the remainder through the overlay binary and reports it to Claude.
calls = []


def fake_run(command, **kwargs):
    calls.append(command)
    text_file = command[command.index("--text-file") + 1]
    with open(text_file, encoding="utf-8") as handle:
        calls.append(handle.read())

    class Result:
        returncode = 0
        stdout = "typed 12 of 12 characters in 1.3s"
        stderr = ""
    return Result()


hook.subprocess.run = fake_run
hook.LINGER_SECONDS = 0
out = io.StringIO()
with contextlib.redirect_stdout(out):
    hook.post(payload)
printed = json.loads(out.getValue() if hasattr(out, "getValue") else out.getvalue())
ok = (calls and calls[0][1] == "type-human" and calls[1] == "erhaba d\u00fcnya" and dict(zip(calls[0][2::2], calls[0][3::2])).get("--sound") == "mechkey"
      and printed["hookSpecificOutput"]["hookEventName"] == "PostToolUse" and "12 characters" in printed["hookSpecificOutput"]["additionalContext"]
      and not os.path.exists(stash))
print("%s asmr post -> type-human called with the remainder, additionalContext returned, stash removed" % ("ok  " if ok else "FAIL"))
failed |= not ok

# ASMR mode: a batch that contains a type action is blocked with an explanation.
command, printed = run_pre({"tool_name": "mcp__computer-use__computer_batch", "tool_use_id": "toolu_test_2", "tool_input": {"actions": [
    {"action": "left_click", "coordinate": [456, 629]}, {"action": "type", "text": "abc"}]}})
ok = command is None and printed["hookSpecificOutput"]["permissionDecision"] == "deny" and "standalone type" in printed["hookSpecificOutput"]["permissionDecisionReason"]
print("%s asmr batch with type -> denied with guidance" % ("ok  " if ok else "FAIL"))
failed |= not ok

# ASMR mode: a single-character type and batches without type actions run normally.
command, printed = run_pre({"tool_name": "mcp__computer-use__computer_batch", "tool_use_id": "toolu_test_3", "tool_input": {"actions": [
    {"action": "left_click", "coordinate": [456, 629]}, {"action": "type", "text": "x"}, {"action": "key", "text": "Return"}]}})
ok = command is not None and printed is None
print("%s asmr batch without long text -> runs normally" % ("ok  " if ok else "FAIL"))
failed |= not ok
sys.exit(1 if failed else 0)

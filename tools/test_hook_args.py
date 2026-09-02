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
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks"))
import hook  # noqa: E402

SCREEN = {"width": 1470, "height": 956, "backingScale": 2.0, "name": "test"}
launched = []


class FakeProcess:
    pid = 4242


def fake_run_overlay(args, timeout=2.0):
    assert args == ["screen"], args
    return SCREEN


def fake_popen(command, **kwargs):
    launched.append(command)
    return FakeProcess()


hook.run_overlay = fake_run_overlay
hook.subprocess.Popen = fake_popen
hook.OVERLAY_BIN = __file__  # any existing path satisfies the existence check

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
        ["554,619,1 left click,click", "735,478,3 scroll,scroll", "107,107,4 drag,drag-start", "321,429,4 drop,drag-end"],
        ['2 typing "2+2"'],
    ),
    (
        {"tool_name": "mcp__computer-use__computer_batch", "tool_input": {"actions": [{"action": "screenshot"}, {"action": "zoom", "region": [0, 0, 10, 10]}]}},
        None,
    ),
    (
        {"tool_name": "mcp__computer-use__type", "tool_input": {"text": "computer use test\nsecond line"}},
        [],
        ['typing "computer use test\u23cesecond line"'],
    ),
    (
        {"tool_name": "mcp__computer-use__computer_batch", "tool_input": {"actions": [
            {"action": "left_click", "coordinate": [456, 629]},
            {"action": "type", "text": "x" * 100},
            {"action": "key", "text": "Return", "repeat": 2},
            {"action": "hold_key", "text": "shift", "duration": 1.5},
        ]}},
        ["489,674,1 left click,click"],
        ['2 typing "' + "x" * 69 + '\u2026" (100 chars)', "3 key Return x2", "4 hold shift for 1.5s"],
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
              and options.get("--key-sound") == "keyboard" and options.get("--scroll-sound") == "none"
              and options.get("--volume") == "0.4" and "--log" in command and options.get("--state-dir") == STATE_DIR)
        print("%s %s -> markers=%s banner=%s" % ("ok  " if ok else "FAIL", hook.action_name(payload["tool_name"]), markers, banner))
    failed |= not ok

# The config file written by `click-overlay use` must win over the environment.
with open(os.environ["CLICK_OVERLAY_CONFIG"], "w", encoding="utf-8") as handle:
    json.dump({"sound": "melody:tetris", "key_sound": "typewriter", "scroll_sound": "bubble", "volume": 0.5}, handle)
launched.clear()
hook.pre(CASES[0][0])
options = dict(zip(launched[0][2::2], launched[0][3::2]))
ok = options.get("--sound") == "melody:tetris" and options.get("--key-sound") == "typewriter" and options.get("--scroll-sound") == "bubble" and options.get("--volume") == "0.5"
print("%s config file overrides environment -> sound=%s key=%s scroll=%s volume=%s" % ("ok  " if ok else "FAIL", options.get("--sound"), options.get("--key-sound"), options.get("--scroll-sound"), options.get("--volume")))
failed |= not ok
sys.exit(1 if failed else 0)

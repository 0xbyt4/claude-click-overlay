#!/usr/bin/env python3
"""Checks the overlay command line the pre hook builds for single actions and batches."""
import os
import sys
import tempfile

os.environ["CLICK_OVERLAY_STATE_DIR"] = tempfile.mkdtemp(prefix="click-overlay-test-")
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
        ["554,619,1 left click,click", "735,478,2 scroll,scroll", "107,107,3 drag,drag-start", "321,429,3 drop,drag-end"],
    ),
    (
        {"tool_name": "mcp__computer-use__computer_batch", "tool_input": {"actions": [{"action": "screenshot"}, {"action": "zoom", "region": [0, 0, 10, 10]}]}},
        None,
    ),
]

failed = False
for payload, expected_markers in CASES:
    launched.clear()
    hook.pre(payload)
    if expected_markers is None:
        ok = launched == []
        print("%s %s -> no overlay launched" % ("ok  " if ok else "FAIL", hook.action_name(payload["tool_name"])))
    else:
        command = launched[0] if launched else []
        markers = [command[i + 1] for i, token in enumerate(command) if token == "--marker"]
        options = dict(zip(command[2::2], command[3::2]))
        ok = markers == expected_markers and options.get("--sound") == "Pop" and options.get("--volume") == "0.4" and "--log" in command
        print("%s %s -> %s sound=%s volume=%s" % ("ok  " if ok else "FAIL", hook.action_name(payload["tool_name"]), markers, options.get("--sound"), options.get("--volume")))
    failed |= not ok
sys.exit(1 if failed else 0)

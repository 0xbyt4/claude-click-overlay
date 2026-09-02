#!/usr/bin/env python3
"""Simulates the CLI's coordinate mapping to check that calibration converges correctly."""
import json
import os
import sys
import tempfile

os.environ["CLICK_OVERLAY_STATE_DIR"] = tempfile.mkdtemp(prefix="click-overlay-test-")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks"))
import hook  # noqa: E402

SCREEN = {"width": 1470, "height": 956, "backingScale": 2.0, "name": "test"}
POINTS = [(456, 629), (1300, 850), (686, 446), (1371, 891), (100, 700), (900, 300)]


def simulate(true_size):
    """Feed clicks through calibrate() with the cursor placed where a CLI using true_size would put it."""
    state = {"cursor": (0, 0)}

    def fake_run_overlay(args, timeout=2.0):
        if args[0] == "screen":
            return SCREEN
        return {"x": state["cursor"][0], "y": state["cursor"][1]}

    hook.run_overlay = fake_run_overlay
    for x, y in POINTS:
        state["cursor"] = hook.to_logical(x, y, SCREEN, true_size)
        hook.calibrate({"tool_name": "mcp__computer-use__left_click", "tool_input": {"coordinate": [x, y]}})
    entry = hook.load_calibration()[hook.screen_key(SCREEN)]
    return (entry["image_width"], entry["image_height"]), entry["source"]


failed = False
# Exact halves must round up like the CLI: 805 * 1470 / 1372 is exactly 862.5 and lands on 863.
half = hook.to_logical(805, 600, SCREEN, (1372, 892))
ok = half == (863, 643)
failed |= not ok
print("%s half-up rounding: image (805, 600) -> %s (expected (863, 643))" % ("ok  " if ok else "FAIL", half))

for true_size, expected_source in [((1372, 892), "predicted"), ((1400, 910), "samples"), ((1360, 884), "samples")]:
    try:
        os.remove(hook.CALIBRATION_FILE)
    except OSError:
        pass
    got, source = simulate(true_size)
    ok = got == true_size and source == expected_source
    failed |= not ok
    print("%s true=%s -> calibrated=%s source=%s" % ("ok  " if ok else "FAIL", true_size, got, source))
sys.exit(1 if failed else 0)

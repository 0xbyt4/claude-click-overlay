#!/usr/bin/env python3
"""Checks the screenshot size prediction against sizes measured on real machines."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks"))
import hook  # noqa: E402

CASES = [
    # (physical width, physical height, expected screenshot width, expected height, note)
    (2560, 1664, 1372, 892, "13-inch class MacBook, measured 2026-09-02 with cursor probes"),
    (3456, 2234, 1372, 887, "16-inch MacBook Pro, from the official computer-use docs"),
    (1280, 800, 1280, 800, "small display, no downscale needed"),
]

failed = False
for width, height, expected_width, expected_height, note in CASES:
    got = hook.predicted_image_size(width, height)
    status = "ok " if got == (expected_width, expected_height) else "FAIL"
    failed |= status == "FAIL"
    print("%s %dx%d -> %dx%d (expected %dx%d) %s" % (status, width, height, got[0], got[1], expected_width, expected_height, note))
sys.exit(1 if failed else 0)

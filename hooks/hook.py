#!/usr/bin/env python3
"""Claude Code hook that previews computer-use actions with an on-screen overlay.

Subcommands (read the hook payload from stdin):
  pre   PreToolUse: draw markers where the upcoming action will land, wait briefly
        so the user sees them, then exit 0 so the action proceeds.
  post  PostToolUse: dismiss the markers and refine the coordinate calibration
        from the real cursor position.

The hook never blocks a tool call. Any internal failure is logged and exits 0.
Nothing is written to stdout, so no text reaches the model's context.
"""

import json
import math
import os
import signal
import statistics
import subprocess
import sys
import time

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_DIR = os.path.expanduser(os.environ.get("CLICK_OVERLAY_STATE_DIR", "~/.cache/claude-click-overlay"))
CALIBRATION_FILE = os.path.join(STATE_DIR, "calibration.json")
PID_FILE = os.path.join(STATE_DIR, "overlay.pid")
LOG_FILE = os.path.join(STATE_DIR, "hook.log")
LOG_MAX_BYTES = 1_000_000

OVERLAY_BIN = os.environ.get("CLICK_OVERLAY_BIN") or os.path.join(REPO_DIR, "overlay", "build", "click-overlay")
PREVIEW_SECONDS = float(os.environ.get("CLICK_OVERLAY_PREVIEW_MS", "600")) / 1000.0
MAX_TTL_SECONDS = float(os.environ.get("CLICK_OVERLAY_MAX_TTL_S", "30"))
LINGER_SECONDS = float(os.environ.get("CLICK_OVERLAY_LINGER_MS", "350")) / 1000.0
OVERLAY_LOG_FILE = os.path.join(STATE_DIR, "overlay.log")
# Sound choice written by `click-overlay use NAME`. The config file wins over the environment so
# a choice made while Claude is running takes effect on the next action without a restart.
CONFIG_FILE = os.path.expanduser(os.environ.get("CLICK_OVERLAY_CONFIG") or "~/.config/claude-click-overlay/config.json")


def load_config():
    try:
        with open(CONFIG_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def sound_settings():
    """Return (sound spec, volume string): config file, then environment, then defaults."""
    config = load_config()
    sound = str(config.get("sound") or os.environ.get("CLICK_OVERLAY_SOUND") or "tick").strip()
    volume = config.get("volume")
    if volume is None:
        volume = os.environ.get("CLICK_OVERLAY_VOLUME") or "0.6"
    return sound or "none", str(volume).strip() or "0.6"

# Claude Code downsamples the screenshot so that the image fits the model's vision budget:
# no side above MAX_TARGET_PX and at most MAX_TARGET_TOKENS tiles of PX_PER_TOKEN pixels.
# These constants and the search below mirror the CLI (verified against 2.1.258, where
# 2560x1664 physical pixels become a 1372x892 screenshot). Calibration samples taken from the
# real cursor position override the prediction if a future CLI changes the rule.
PX_PER_TOKEN = 28
MAX_TARGET_PX = 1568
MAX_TARGET_TOKENS = 1568

TOOL_PREFIX = "mcp__computer-use__"
CLICK_ACTIONS = {"left_click", "right_click", "middle_click", "double_click", "triple_click"}
POINTER_ACTIONS = CLICK_ACTIONS | {"scroll", "mouse_move", "left_click_drag"}
MAX_CALIBRATION_SAMPLES = 12


def log(message):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_BYTES:
            os.replace(LOG_FILE, LOG_FILE + ".1")
        with open(LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + message + "\n")
    except OSError:
        pass


def run_overlay(args, timeout=2.0):
    result = subprocess.run([OVERLAY_BIN] + args, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError("overlay %s failed: %s" % (args[0], result.stderr.strip()))
    return json.loads(result.stdout)


def screen_key(screen):
    return "%dx%d@%g" % (screen["width"], screen["height"], screen["backingScale"])


def load_calibration():
    try:
        with open(CALIBRATION_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def save_calibration(data):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = CALIBRATION_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
    os.replace(tmp, CALIBRATION_FILE)


def js_round(value):
    """JavaScript Math.round: halves round toward positive infinity."""
    return math.floor(value + 0.5)


def tile_count(width, height):
    return ((width - 1) // PX_PER_TOKEN + 1) * ((height - 1) // PX_PER_TOKEN + 1)


def predicted_image_size(pixel_width, pixel_height):
    """Screenshot size the CLI produces for a display of the given physical pixel size."""
    if pixel_width <= MAX_TARGET_PX and pixel_height <= MAX_TARGET_PX and tile_count(pixel_width, pixel_height) <= MAX_TARGET_TOKENS:
        return pixel_width, pixel_height
    if pixel_height > pixel_width:
        height, width = predicted_image_size(pixel_height, pixel_width)
        return width, height
    aspect = pixel_width / pixel_height
    low, high = 1, pixel_width
    while True:
        if low + 1 == high:
            return low, max(js_round(low / aspect), 1)
        mid = (low + high) // 2
        mid_height = max(js_round(mid / aspect), 1)
        if mid <= MAX_TARGET_PX and tile_count(mid, mid_height) <= MAX_TARGET_TOKENS:
            low = mid
        else:
            high = mid


def image_size(screen, calibration):
    """Return (image_width, image_height, source) for the current display."""
    entry = calibration.get(screen_key(screen))
    if entry and entry.get("image_width") and entry.get("image_height"):
        return entry["image_width"], entry["image_height"], "calibrated"
    scale = screen["backingScale"]
    width, height = predicted_image_size(js_round(screen["width"] * scale), js_round(screen["height"] * scale))
    return width, height, "predicted"


def to_logical(x, y, screen, size):
    image_width, image_height = size
    return (
        round(x * screen["width"] / image_width),
        round(y * screen["height"] / image_height),
    )


def action_name(tool_name):
    return tool_name[len(TOOL_PREFIX):] if tool_name.startswith(TOOL_PREFIX) else tool_name


def pointer_actions(tool_name, tool_input):
    """Yield (action, coordinate, start_coordinate) for every pointer action in the call."""
    name = action_name(tool_name)
    if name == "computer_batch":
        for action in tool_input.get("actions") or []:
            kind = action.get("action")
            if kind in POINTER_ACTIONS and action.get("coordinate"):
                yield kind, action["coordinate"], action.get("start_coordinate")
    elif name in POINTER_ACTIONS and tool_input.get("coordinate"):
        yield name, tool_input["coordinate"], tool_input.get("start_coordinate")


def marker_args(actions, screen, size):
    markers = []
    total_clicks = sum(1 for kind, _, _ in actions if kind != "mouse_move")
    index = 0
    for kind, coordinate, start in actions:
        if kind == "mouse_move":
            continue
        index += 1
        number = "%d " % index if total_clicks > 1 else ""
        x, y = to_logical(coordinate[0], coordinate[1], screen, size)
        if kind == "left_click_drag":
            if start:
                sx, sy = to_logical(start[0], start[1], screen, size)
                markers.append("%d,%d,%sdrag,drag-start" % (sx, sy, number))
            markers.append("%d,%d,%sdrop,drag-end" % (x, y, number))
        elif kind == "scroll":
            markers.append("%d,%d,%sscroll,scroll" % (x, y, number))
        else:
            label = kind.replace("_", " ")
            markers.append("%d,%d,%s%s,click" % (x, y, number, label))
    args = []
    for marker in markers:
        args += ["--marker", marker]
    return args


def stop_overlay():
    try:
        with open(PID_FILE, encoding="utf-8") as handle:
            pid = int(handle.read().strip())
    except (OSError, ValueError):
        return
    try:
        os.remove(PID_FILE)
    except OSError:
        pass
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass


def pre(payload):
    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input") or {}
    actions = list(pointer_actions(tool_name, tool_input))
    if not any(kind != "mouse_move" for kind, _, _ in actions):
        return
    if not os.path.exists(OVERLAY_BIN):
        log("overlay binary missing at %s; run install.sh" % OVERLAY_BIN)
        return
    screen = run_overlay(["screen"])
    width, height, source = image_size(screen, load_calibration())
    args = marker_args(actions, screen, (width, height))
    stop_overlay()
    if os.path.exists(OVERLAY_LOG_FILE) and os.path.getsize(OVERLAY_LOG_FILE) > LOG_MAX_BYTES:
        os.replace(OVERLAY_LOG_FILE, OVERLAY_LOG_FILE + ".1")
    sound, volume = sound_settings()
    process = subprocess.Popen(
        [OVERLAY_BIN, "show", "--ttl", str(MAX_TTL_SECONDS), "--sound", sound, "--volume", volume, "--log", OVERLAY_LOG_FILE, "--state-dir", STATE_DIR] + args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(PID_FILE, "w", encoding="utf-8") as handle:
        handle.write(str(process.pid))
    log("pre %s markers=%s image=%dx%d(%s) sound=%s pid=%d" % (action_name(tool_name), args[1::2], width, height, source, sound, process.pid))
    time.sleep(PREVIEW_SECONDS)


def consistent(size, samples, screen):
    """True when the given image size reproduces every observed cursor position exactly."""
    return all(to_logical(sx, sy, screen, size) == (cx, cy) for sx, sy, cx, cy in samples)


def best_size(samples, screen, predicted):
    """Smallest integer image size that explains all samples, nearest to the ratio estimate."""
    last_x, last_y, cursor_x, cursor_y = samples[-1]
    implied_width = screen["width"] * last_x / cursor_x
    implied_height = screen["height"] * last_y / cursor_y
    widths = [w for w in range(js_round(implied_width) - 6, js_round(implied_width) + 7) if w > 0]
    heights = [h for h in range(js_round(implied_height) - 6, js_round(implied_height) + 7) if h > 0]
    candidates = [(w, h) for w in widths for h in heights if consistent((w, h), samples, screen)]
    if not candidates:
        return None
    return min(candidates, key=lambda size: (abs(size[0] - implied_width) + abs(size[1] - implied_height), abs(size[0] - predicted[0]) + abs(size[1] - predicted[1])))


def calibrate(payload):
    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input") or {}
    actions = list(pointer_actions(tool_name, tool_input))
    if not actions:
        return
    kind, coordinate, _ = actions[-1]
    if kind == "left_click_drag":
        return
    x, y = coordinate
    screen = run_overlay(["screen"])
    cursor = run_overlay(["cursor"])
    cursor_x, cursor_y = js_round(cursor["x"]), js_round(cursor["y"])
    if x < 50 or y < 50 or cursor_x <= 0 or cursor_y <= 0:
        return
    predicted = image_size(screen, {})[:2]
    calibration = load_calibration()
    key = screen_key(screen)
    entry = calibration.get(key) or {}
    current = (entry.get("image_width"), entry.get("image_height")) if entry.get("image_width") else predicted
    sample = [x, y, cursor_x, cursor_y]

    if consistent(predicted, [sample], screen):
        # The CLI behaves as predicted. Drop any sample-derived override and count the confirmation.
        if current != predicted:
            log("calibration %s: prediction %dx%d confirmed again, dropping override %dx%d" % (key, predicted[0], predicted[1], current[0], current[1]))
        entry = {"image_width": predicted[0], "image_height": predicted[1], "source": "predicted",
                 "confirmations": int(entry.get("confirmations", 0)) + 1, "samples": [],
                 "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
        calibration[key] = entry
        save_calibration(calibration)
        return

    # Prediction misses: the cursor might have been moved by hand, or the CLI changed its rule.
    implied_width = screen["width"] * x / cursor_x
    implied_height = screen["height"] * y / cursor_y
    if abs(implied_width - current[0]) > 0.05 * current[0] or abs(implied_height - current[1]) > 0.05 * current[1]:
        log("calibration sample ignored: implied %.1fx%.1f is far from %dx%d (cursor moved by hand?)" % (implied_width, implied_height, current[0], current[1]))
        return
    samples = [s for s in entry.get("samples", []) if len(s) == 4][-(MAX_CALIBRATION_SAMPLES - 1):] + [sample]
    size = best_size(samples, screen, predicted)
    if size is None:
        # Contradictory samples, most likely a hand-moved cursor. Keep the newest sample only.
        samples = [sample]
        size = best_size(samples, screen, predicted) or current
    entry = {"image_width": size[0], "image_height": size[1], "source": "samples", "samples": samples,
             "confirmations": 0, "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    calibration[key] = entry
    save_calibration(calibration)
    log("calibration %s: prediction %dx%d does not match, using %dx%d from %d sample(s)" % (key, predicted[0], predicted[1], size[0], size[1], len(samples)))


def post(payload):
    if LINGER_SECONDS > 0 and os.path.exists(PID_FILE):
        time.sleep(LINGER_SECONDS)
    stop_overlay()
    if os.path.exists(OVERLAY_BIN):
        calibrate(payload)


def main():
    if os.environ.get("CLICK_OVERLAY_DISABLE") == "1":
        return
    if len(sys.argv) != 2 or sys.argv[1] not in ("pre", "post"):
        sys.stderr.write("usage: hook.py pre|post\n")
        return
    try:
        payload = json.load(sys.stdin)
    except ValueError as error:
        log("invalid payload: %s" % error)
        return
    if not str(payload.get("tool_name", "")).startswith(TOOL_PREFIX):
        return
    try:
        if sys.argv[1] == "pre":
            pre(payload)
        else:
            post(payload)
    except Exception as error:  # never block computer use because of the overlay
        log("%s failed: %r" % (sys.argv[1], error))


if __name__ == "__main__":
    main()

# Experiments

Measurements behind the design decisions. Environment: macOS 26 (Darwin 25.2.0),
Claude Code CLI 2.1.258 with the built-in `computer-use` MCP server, one built-in Retina display
of 1470x956 points at 2x (2560x1664 pixels). Date: 2026-09-02.

## 1. Does computer use hide a third-party overlay window?

Computer use hides applications that are not in the session allowlist while it works, so the
first question was whether a marker window would survive.

Setup: an accessory-policy app (no Dock icon) with a borderless, transparent, click-through
window at the shielding window level, drawn over the Calculator "5" key. The app logged
`didHide`, `didUnhide`, and occlusion changes every second (`tools/overlay_probe.swift`).

Sequence run through computer use: screenshot, left click on "5", zoom, screenshot.

| Check | Result |
| :-- | :-- |
| App hidden at any point | No. `hidden=false` for the whole run, no hide events |
| Window still on screen afterwards | Yes, `CGWindowList` listed it with alpha 1 |
| Click passes through the overlay | Yes, Calculator received the "5" |
| Overlay visible in the model's screenshots | No, native screenshot filtering excludes it |

Conclusion: an overlay that is not in the allowlist stays visible to the user and invisible to
the model, and it does not interfere with clicks.

## 2. Coordinate mapping between screenshot pixels and screen points

The model addresses the screen in the pixel space of a downscaled screenshot. To measure the
mapping, a background sampler recorded the real cursor position 20 times per second
(`tools/cursor_sampler.swift`) while a `computer_batch` issued `mouse_move` actions.

| Requested (image px) | Measured cursor (points) | x ratio | y ratio |
| :-- | :-- | :-- | :-- |
| 100, 100 | 107, 107 | 1.070 | 1.070 |
| 686, 446 | 735, 478 | 1.0714 | 1.0717 |
| 1300, 850 | 1393, 911 | 1.0715 | 1.0718 |
| 1371, 891 | 1469, 955 | 1.0715 | 1.0718 |
| 10, 880 | 11, 943 | 1.100 | 1.0716 |
| 1372, 892 | 1469, 955 | clamped | clamped |

The request `1372, 892` lands on the same point as `1371, 891`, so the screenshot is
1372x892 px and coordinates are clamped to it. Every measured point equals
`round(x * 1470 / 1372)`, `round(y * 956 / 892)`, so the two axes use separate factors and the
result is rounded to whole points. `cursor_position` reported `1371, 891` for the last move,
closing the round trip. Maximum deviation of the mapping: 0.5 point.

## 3. Screenshot sizing rule

The CLI computes the screenshot size from the display's physical pixels with a token budget:
`pxPerToken = 28`, `maxTargetPx = 1568`, `maxTargetTokens = 1568`. It keeps the native size
when both sides are within 1568 px and the tile count `ceil(w/28) * ceil(h/28)` stays within
1568, otherwise it binary-searches the largest width whose proportional height satisfies both
limits. `hooks/hook.py` ports this search; `tools/test_sizing.py` checks it against the
measured 1372x892 and the 1372x887 quoted in the official docs for a 3456x2234 display.

A fixed width of 1372 would be wrong for other aspect ratios, for example a 16:10 display
ends up wider and a 4:3 display narrower, which is why the port replaced the constant.

## 4. Hook end to end

With the hooks active, a single `left_click` at image `456, 629` (the Calculator "7" key):

| Check | Result |
| :-- | :-- |
| Marker position computed by the pre hook | 489, 674 points, from the predicted 1372x892 |
| Expected position from the measured rule | 489, 674 |
| Click landed on "7" | Yes, display showed `57` |
| Tool result text in the transcript | `Clicked.` only, no hook output |
| Transcript entries mentioning hooks | 0 |
| Added latency | 600 ms preview before the click, 350 ms linger after |

A `computer_batch` with four clicks (`AC`, `1`, `+`, `2`) and a Return key produced four
numbered markers in one overlay and the display showed `3`.

## 5. Calibration

The first version estimated the image width from the ratio of requested to measured position.
One sample at `456` gave `1370.8`, which rounds to 1371, because half a point of rounding in
the cursor position is amplified by the ratio. The calibration now asks a different question:
does the predicted size reproduce the observed cursor position exactly? If yes, the prediction
is confirmed and any override is dropped. If no, the hook keeps a list of samples and picks the
integer size that explains all of them. `tools/test_calibration.py` simulates a CLI using
1372x892, 1400x910, and 1360x884 and checks that the hook converges to each.

## 6. Detecting the click for sound and animation

The sound should play when the click lands, not when the marker appears, and a batch should
produce one sound per click. The hooks cannot provide that timing: `PreToolUse` runs before the
whole batch and `PostToolUse` after it. So the overlay itself listens with
`NSEvent.addGlobalMonitorForEvents` for mouse-down events, which needs no extra permission for
mouse events.

Test: a `computer_batch` with two clicks in System Settings (back arrow, then About), with the
overlay logging every mouse-down it observes.

| Marker drawn at (points) | Mouse-down observed at (points) | Sound |
| :-- | :-- | :-- |
| 640, 81 | 640, 81 | played |
| 691, 303 | 691, 303 | played |

The synthetic clicks posted by computer use reach the global monitor exactly like physical
clicks, at the predicted positions. The overlay marks the nearest ring as pressed, plays the
configured sound, and the post hook dismisses it afterwards. A failed action (the batch
stopped because the target window belonged to an app outside the allowlist) produced markers
but no mouse-down, and the calibration guard correctly ignored the resulting cursor sample.

## 7. Synthesized sounds

All bundled sounds are generated in code, so their character can be checked objectively by
rendering them to WAV (`click-overlay render NAME file.wav`) and measuring duration, peak,
RMS level, and the dominant frequency in the first and last quarter (zero-crossing rate).

| Preset | Duration | RMS | Pitch start | Pitch end | Intended character |
| :-- | :-- | :-- | :-- | :-- | :-- |
| tick | 0.045 s | 0.15 | 2134 Hz | 1778 Hz | short neutral click |
| pew | 0.22 s | 0.18 | 1064 Hz | 209 Hz | descending laser |
| jump | 0.18 s | 0.31 | 345 Hz | 878 Hz | rising jump |
| boom | 0.85 s | 0.30 | 221 Hz | 28 Hz | bass drop |
| fart | 0.45 s | 0.40 | 111 Hz | 151 Hz | low wobble |
| airhorn | 0.75 s | 0.69 | 651 Hz | 685 Hz | loud sustained chord |
| rimshot | 0.90 s | 0.17 | 80 Hz | 9038 Hz | two kicks then hiss |
| trombone | 1.85 s | 0.41 | 221 Hz | 171 Hz | four falling notes |
| coin | 0.42 s | 0.30 | 1272 Hz | 1567 Hz | two-tone chime |

Every preset renders and plays without error, unknown names fail with a clear message, and
peaks are normalized so the volume setting behaves the same across presets. Whether they are
funny is a matter of taste that no measurement settles; `click-overlay play NAME` is the test.

Melody mode was checked live: a batch of ten Calculator clicks played Korobeiniki notes 1 to
10, and a second batch continued with notes 11 to 13, because the position is persisted in the
state directory between overlay processes.

## 8. Typing, keys, and scrolling

A `computer_batch` in a new TextEdit document: click into the page, type a 19-character
sentence, press Return, type a 40-character sentence, then scroll down 5 ticks. The pre hook
produced two markers (click and scroll) and three banner lines (two typing lines and the key),
numbered 1 to 5 in execution order and shown together before the batch started.

| Event source | Observed by the overlay | Sound |
| :-- | :-- | :-- |
| 1 left click | 1 mouse-down at the marker | tick |
| 19 + 1 + 40 keystrokes | 60 key-down events | keyboard, 60 times |
| 1 scroll gesture of 5 ticks | 1 scroll event with dy = -5 | bubble |

The global key monitor only delivers events to a process trusted for Accessibility. The
overlay is spawned by the hook inside the terminal session, so it inherits the terminal's
Accessibility grant that computer use itself requires; the overlay logs
`accessibilityTrusted=true` at startup so a missing grant is visible in the log. Keystrokes
posted by computer use arrive with `keyCode=0`, which is why the banner counts keystrokes
instead of decoding them.

## 9. Dropped key events and the audio engine

A 783-character note produced only 341 key-down events in the overlay, while a 60-character
test earlier had produced all 60. Three controlled `type` calls of 100 characters each
(ASCII on one line, ASCII with newlines, Turkish letters) all showed one character per event
(`chars=1`) but only 59 to 74 events, so the sender was posting every keystroke and the overlay
was missing some. Repeating the ASCII line with the key sound disabled captured 100 of 100.

Cause: the key monitor handler restarted an `NSSound` and wrote the log file synchronously on
every keystroke. Computer use types at about 100 keystrokes per second, and a global monitor
whose handler cannot keep up loses events instead of queueing them.

Fix: playback moved to one shared `AVAudioEngine` with prepared PCM buffers, where scheduling a
sound costs microseconds and sounds overlap on a small pool of player nodes; log writes moved
to a background queue; the key sound is rate-limited to one per 30 ms while every keystroke is
still counted and flashes the banner.

| Test | Before | After |
| :-- | :-- | :-- |
| 100 ASCII characters, key sound on | 59 events | 101 of 101 (with a leading newline) |
| 100 Turkish letters, key sound on | 69 events | 101 of 101 |
| 849-character note in four `type` actions plus cmd+n | not run | 850 of 850, 91 keys/s, 237 sounds played |

## 10. Mechanical mouse and keyboard defaults

The default click and key sounds imitate an old mechanical mouse microswitch and an old clicky
mechanical keyboard. Both are layered: a broadband high-passed tick for the metal snap, short
bright ringing, a lower body resonance, and a second, lighter hit for the release. The keyboard
adds a low-passed noise thud with 220 and 380 Hz tones for the keycap bottoming out. Each has
several variants (4 for the mouse, 6 for the keyboard) with pitch and release-timing offsets,
chosen at random per event.

Envelope of variant 0, RMS per 5 ms window with the dominant frequency estimate:

| Preset | 0 ms | 5 to 30 ms | Release |
| :-- | :-- | :-- | :-- |
| mouse | 0.19 RMS, bright (ringing at 4.2 and 6.3 kHz) | fades within 10 ms | 70 ms, 0.11 RMS |
| mechkey | 0.14 RMS, bright (2.6 and 3.9 kHz) | 0.28 falling to 0.03 RMS at 200 to 300 Hz | 65 ms, 0.12 RMS |

Whether they feel like the real thing is for ears to judge; the structure, two distinct hits
with a bright snap and a low body, matches recordings of such switches in shape and timing.

## 11. Cold start and the readiness handshake

Navigating System Settings, the first click of the sequence drew its marker but the overlay
recorded no mouse-down, while the next four actions were complete. The hook log showed the
pre hook at second 01 and the overlay's `shown` line at 04.2: that overlay instance took
about 3 seconds to start, against 170 to 225 ms for the instances measured right after. The
600 ms preview had long expired, so the click happened before the markers were visible and
before the monitors existed. The slow part is the audio engine, which can take seconds to
start when the output device has gone idle.

Two changes. The overlay now shows the markers and installs the monitors first, signals
readiness by creating a file, and only then builds the sound players on a background thread;
an event that arrives before audio is ready is still counted and animated, just silent. The
hook waits for the ready file, capped at 3 seconds by `CLICK_OVERLAY_READY_TIMEOUT_MS`, and
starts the preview delay after it, so the marker is on screen for the full preview before the
action runs and a stuck overlay can never hold up computer use for more than the cap.

| Measurement | Value |
| :-- | :-- |
| Spawn to ready (monitors installed), warm | 112 ms |
| Audio ready after that | 93 to 97 ms |
| Live click after the change | mouse-down captured 796 ms after `shown`, with sound |

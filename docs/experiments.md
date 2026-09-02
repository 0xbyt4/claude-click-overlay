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

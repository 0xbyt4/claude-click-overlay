# claude-click-overlay

Shows you where Claude Code is about to click before it clicks.

When the Claude Code CLI drives your Mac through its built-in `computer-use` MCP server, the
only feedback you get is the cursor jumping around. This tool adds a transparent, click-through
overlay that draws a pulsing ring, a crosshair, and a label at the exact spot each action will
land, roughly half a second before it happens. Batches of actions get numbered markers so you can
see the whole plan at once.

When a click lands, the overlay plays a short sound and the ring collapses with a ripple, so you
hear and see the moment it happens. Pick the sound you like or turn it off.

It is implemented entirely with Claude Code hooks, so:

- **Zero extra tokens.** The hooks print nothing to stdout. Nothing reaches the model's context.
  Verified by inspecting the session transcript: the tool result stays exactly `Clicked.`
- **No new MCP server.** The model does not know the overlay exists and cannot forget to use it.
- **Never blocks computer use.** Every failure path logs and exits 0.
- **Invisible to Claude.** The overlay is not in the computer-use allowlist, so it is excluded
  from the screenshots the model sees, yet macOS keeps it on top for you.

## How it works

1. A `PreToolUse` hook matches the computer-use click, scroll, drag, and batch tools. It reads
   the coordinates from the tool input, converts them from screenshot pixels to screen points,
   launches the overlay, waits for the preview delay, and exits so the action proceeds.
2. The overlay watches for mouse-down events with a global monitor. Synthetic clicks posted by
   computer use reach it like real ones, so the sound and the press animation fire at the exact
   moment each click lands, one per click even inside a batch.
3. A `PostToolUse` hook dismisses the overlay and compares the real cursor position with the
   requested coordinate to confirm the coordinate mapping.

### Coordinate mapping

The model sends coordinates in the pixel space of a downscaled screenshot. Claude Code sizes the
screenshot so it fits the model's vision budget: no side longer than 1568 px and at most 1568
tiles of 28 px. The hook ports that exact search, so on a 2560x1664 display it predicts a
1372x892 screenshot without ever seeing one. The mapping then is
`screen_x = round(x * screen_width / image_width)` and the same for `y`, matching the CLI to the
point. Details and measurements are in [docs/experiments.md](docs/experiments.md).

If a future Claude Code version changes the rule, the post hook notices that the prediction no
longer reproduces the observed cursor position and switches to a size derived from samples.

## Requirements

- macOS (the computer-use MCP server is macOS only in the CLI)
- Claude Code CLI with `computer-use` enabled in `/mcp` (Pro or Max plan)
- Xcode Command Line Tools for `swiftc`, and `python3`

## Install

```sh
git clone git@github.com:0xbyt4/claude-click-overlay.git
cd claude-click-overlay
./install.sh           # builds, tests, prints the hook config
./install.sh --user    # additionally merges the hooks into ~/.claude/settings.json
```

Claude Code picks up settings changes automatically. Ask Claude to click something and watch
for the red ring.

For development inside this repository, the checked-in `.claude/settings.json` wires the hooks
through `$CLAUDE_PROJECT_DIR`, so a Claude Code session started in the repo directory uses the
working copy directly.

## Configuration

Environment variables read by the hook:

| Variable | Default | Meaning |
| :-- | :-- | :-- |
| `CLICK_OVERLAY_PREVIEW_MS` | `600` | How long the marker is shown before the action runs |
| `CLICK_OVERLAY_LINGER_MS` | `350` | How long the marker stays after the action finishes |
| `CLICK_OVERLAY_MAX_TTL_S` | `30` | Safety limit for an overlay that is never dismissed |
| `CLICK_OVERLAY_SOUND` | `tick` | Click sound: `tick`, `none`, a macOS system sound, or an audio file path |
| `CLICK_OVERLAY_VOLUME` | `0.6` | Sound volume from `0` to `1` |
| `CLICK_OVERLAY_BIN` | `overlay/build/click-overlay` | Overlay binary location |
| `CLICK_OVERLAY_STATE_DIR` | `~/.cache/claude-click-overlay` | Log, pid, and calibration files |
| `CLICK_OVERLAY_DISABLE` | unset | Set to `1` to turn the hook into a no-op |

Set them in the `env` block of your Claude Code settings or in the shell that starts Claude:

```json
{
  "env": {
    "CLICK_OVERLAY_SOUND": "Pop",
    "CLICK_OVERLAY_VOLUME": "0.4"
  }
}
```

## Sounds

`tick` is a synthesized 45 ms click that ships with the tool. Every macOS system sound works
too: Tink, Pop, Morse, Ping, Glass, Bottle, Frog, Funk, Hero, Purr, Sosumi, Submarine, Blow,
and Basso. Names are case-insensitive. A path to an `.aiff`, `.wav`, `.caf`, or `.mp3` file
uses your own sound, and `none` keeps the overlay silent.

Preview them before choosing:

```sh
overlay/build/click-overlay sounds          # list the options
overlay/build/click-overlay play tick
overlay/build/click-overlay play Pop --volume 0.4
```

## Markers

| Action | Marker |
| :-- | :-- |
| left, right, middle, double, triple click | red ring with crosshair and the click type |
| scroll | blue ring labelled `scroll` |
| left_click_drag | orange start and end rings joined by a dashed line |
| computer_batch | one marker per pointer action, numbered in execution order |

Press `Esc` to abort computer use as usual. The overlay fades out on its own.

## Limitations

- Primary display only. Markers for actions on a second monitor are not drawn yet.
- Claude Code CLI only. The Desktop app has its own computer-use implementation.
- Computer use itself is a research preview. The hook targets the tool names and screenshot
  sizing of Claude Code 2.1.258. The sizing is self-checking, the tool names are not.

## Troubleshooting

- `~/.cache/claude-click-overlay/hook.log` records every marker and calibration decision.
- `~/.cache/claude-click-overlay/calibration.json` shows the image size in use per display.
- `overlay/build/click-overlay screen` and `... cursor` print what the hook sees.
- `/hooks` inside Claude Code lists the active hooks and their source.

## Development

```sh
python3 tools/test_sizing.py        # screenshot size prediction against measured sizes
python3 tools/test_calibration.py   # calibration convergence in simulation
python3 tools/test_hook_args.py     # overlay command line built by the pre hook
```

`tools/` also contains the probes used for the measurements in `docs/experiments.md`.

## License

MIT, see [LICENSE](LICENSE).

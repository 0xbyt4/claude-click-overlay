# claude-click-overlay

Shows you where Claude Code is about to click before it clicks.

When the Claude Code CLI drives your Mac through its built-in `computer-use` MCP server, the
only feedback you get is the cursor jumping around. This tool adds a transparent, click-through
overlay that draws a pulsing ring, a crosshair, and a label at the exact spot each action will
land, roughly half a second before it happens. Batches of actions get numbered markers so you can
see the whole plan at once.

When a click lands, the overlay plays a sound and the ring collapses with a ripple, so you hear
and see the moment it happens. Choose from two dozen synthesized sounds, a random mode, tunes
that advance one note per click, spoken words, your own audio file, or silence.

It is implemented entirely with Claude Code hooks, so:

- **Zero extra tokens.** The hooks print nothing to stdout. Nothing reaches the model's context.
  Verified by inspecting the session transcript: the tool result stays exactly `Clicked.`
- **No new MCP server.** The model does not know the overlay exists and cannot forget to use it.
- **Never blocks computer use.** Every failure path logs and exits 0.
- **Invisible to Claude.** The overlay is not in the computer-use allowlist, so it is excluded
  from the screenshots the model sees, yet macOS keeps it on top for you.

## How it works

1. A `PreToolUse` hook matches the computer-use click, scroll, drag, type, key, and batch
   tools. It reads coordinates and text from the tool input, converts coordinates from
   screenshot pixels to screen points, launches the overlay with markers and a banner, waits
   for the preview delay, and exits so the action proceeds.
2. The overlay watches for mouse-down, key-down, and scroll events with global monitors.
   Synthetic events posted by computer use reach them like real ones, so sounds and animations
   fire at the exact moment each click, keystroke, or scroll lands, one per event even inside a
   batch. Key events need the Accessibility permission you already granted for computer use.
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
| `CLICK_OVERLAY_MAX_TTL_S` | `120` | Safety limit for an overlay that is never dismissed |
| `CLICK_OVERLAY_SOUND` | `tick` | Click sound, see [Sounds](#sounds) |
| `CLICK_OVERLAY_KEY_SOUND` | `keyboard` | Sound per keystroke while Claude types |
| `CLICK_OVERLAY_SCROLL_SOUND` | `none` | Sound per scroll gesture |
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

Every bundled sound is synthesized in code when it plays, so the repository contains no audio
files and nothing with a third-party license. Pick one with `click-overlay use`, which writes a
small config file the hook reads on every action, so the change applies to the next click
without restarting Claude Code:

```sh
overlay/build/click-overlay sounds                 # list everything
overlay/build/click-overlay play fart              # preview one
overlay/build/click-overlay use fart --volume 0.5  # make it the click sound
overlay/build/click-overlay use --clear            # back to the default tick
```

| Spec | What you hear |
| :-- | :-- |
| `tick` | short neutral click, the default |
| `bubble`, `blip`, `beep`, `ding`, `woodblock` | soft UI-style clicks and a small bell |
| `typewriter`, `keyboard`, `shutter` | typewriter key, mechanical switch, camera shutter |
| `drum`, `rimshot` | kick drum, ba-dum-tss |
| `pew`, `jump`, `coin`, `powerup`, `robot` | chiptune laser, jump, coin, rising arpeggio, beep-boop |
| `boing`, `boom`, `airhorn`, `fart`, `trombone`, `quack` | spring, bass drop, air horn, the classic, sad trombone, duck |
| `Tink`, `Pop`, `Morse`, ... | any macOS system sound, case-insensitive |
| `~/Sounds/meme.wav` | your own `.aiff`, `.wav`, `.caf`, or `.mp3` file |
| `random` | a different preset on every click |
| `random:fart,boing,quack` | a random pick from your own list |
| `melody:tetris` | one note of a tune per click: `scale`, `twinkle`, `ode`, `birthday`, `jingle`, `tetris`, `elise` |
| `say:nice` | speaks the text with the system voice |
| `none` | silent |

Clicks, keystrokes, and scrolling each have their own sound. Defaults: `tick` for clicks,
`keyboard` for keystrokes, `none` for scrolling.

```sh
overlay/build/click-overlay use coin --key typewriter --scroll bubble
overlay/build/click-overlay use --key none          # keep clicks, silence typing
```

Melodies remember their position between actions, so a long batch of clicks plays the tune
straight through and the next call continues where it stopped. The tunes are public-domain
melodies rendered as chiptune notes. Meme sounds from the internet are usually copyrighted, which
is why none ship here; point `use` at a file you have the rights to instead.

`CLICK_OVERLAY_SOUND`, `CLICK_OVERLAY_KEY_SOUND`, `CLICK_OVERLAY_SCROLL_SOUND`, and
`CLICK_OVERLAY_VOLUME` in the environment still work as defaults; the config file wins when both
are set.

## Markers

| Action | Marker |
| :-- | :-- |
| left, right, middle, double, triple click | red ring with crosshair and the click type |
| scroll | blue ring labelled `scroll` |
| left_click_drag | orange start and end rings joined by a dashed line |
| type, key, hold_key | a banner at the top of the screen showing the text or key about to be sent |
| computer_batch | one marker or banner line per action, numbered in execution order |

While Claude types, every keystroke flashes the banner border and plays the key sound. Computer
use types at roughly 100 keystrokes per second, so the key sound is rate-limited to one per
30 ms; the count and the flash still follow every keystroke. A scroll gesture plays the scroll
sound and pulses its blue marker.

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

# gemba-core

A lean, **headless** binding to [libmgba](https://mgba.io)'s `mCore` — boot a GBA
ROM, step it a frame at a time, and read back video, audio, and memory as plain
Ruby data. No UI of any kind.

It's a lean subset of the `gemba` emulator's native core — just the headless
mCore binding, none of the GUI stack (`teek`, `teek-sdl2`, `teek-ui`) — so
ruby-gba's tests and dev tooling can verify a ROM against a real emulator. It is
**not published as a gem**; it lives inside the ruby-gba repo for development
only, kept deliberately close to gemba's C so the two can be re-synced.

## What it's for

Answering *"what is this ROM actually doing, frame by frame?"* — the same
question the ruby-gba `Verifier` answers, but through a minimal dependency you
can build in seconds.

```ruby
require "gemba_core"

probe = GembaCore.open("game.gba")
probe.step(6)                 # advance 6 frames
probe.pixel(120, 80)          # => [255, 0, 0]   (r, g, b)
probe.read16(0x04000000)      # => 0x403          DISPCNT: Mode 3 + BG2
probe.snapshot                # => {frame: 6, width: 240, lit_pixels: 38400, ...}
probe.step(10, keys: :right)  # hold RIGHT for 10 frames
probe.audio_energy            # => rough loudness of the last step
probe.close
```

`GembaCore::Core` is the thin native wrapper (`run_frame`, `video_buffer`,
`audio_buffer`, `bus_read8/16/32`, `set_keys`, …). `GembaCore::Probe` sits on
top and returns structured data.

## Building & testing

Needs libmgba installed (`brew install mgba`, `apt install libmgba-dev`, or a
local build pointed at with `MGBA_DIR=...`). From the ruby-gba repo root:

```
rake test:mgba      # compile the extension and run gemba-core's own tests
```

Its tests are kept separate from ruby-gba's main suite; `rake test` does not run
them.

## rcheevos (RetroAchievements)

The achievement evaluator from gemba is **compiled out** by default — a plain
build links nothing but libmgba. The code is still here, guarded by
`#ifdef GEMBA_CORE_RCHEEVOS`. To bring it back, point at an rcheevos checkout at
build time; the extconf defines the macro and adds the sources:

```
GEMBA_CORE_RCHEEVOS=/path/to/rcheevos rake compile
```

No code surgery — flip the flag and the `GembaCore::RARuntime` class reappears.

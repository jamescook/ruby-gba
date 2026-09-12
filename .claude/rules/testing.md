---
paths:
  - "test/**/*.rb"
---

# Testing rules — `test/`

Helpers and patterns already established in this suite. Reach for these before
inventing new scaffolding. The *philosophy* (what to assert at which altitude,
the cross-backend rule) lives in `.claude/CLAUDE.md`; this file is the practical
how — the APIs and worked examples.

## How a test file starts

**One require, nothing else:**

```ruby
# frozen_string_literal: true

require "test_helper"

class TestThing < Minitest::Test
  def test_it_does_the_thing
    ...
  end
end
```

`test_helper` pulls in minitest and the library, and hands every test these
names and helpers with nothing to declare:

- `Reference` (the oracle backend), `GBA` (the ROM lowering), `Builder`, `Color`, `ROM`
- `EmulatorSupport` — `assert_emulator_loads_rom`, `assemble_rom`, `require_emulator!`

It does that by reopening `Minitest::Test` and including them — the Minitest
equivalent of RSpec's `config.include`. **Do not re-declare those constants in a
test file.** If a file needs one of those names for something else, just declare
it: a constant in the file wins over the shared one (see `test_cost_printer.rb`,
which points `Color` at the printer's palette).

Narrower helpers stay **opt-in**, so their names appear only where used:
`include Differential`, `include CostArith`, `include RubyGBA::IR::Build`.

Running them. **The suite is `rake test:parallel`** — it spreads the files over processes and
finishes in a fraction of the time. Bare `rake test` runs the lot in one process, so use it
only to name ONE file or one test:

```bash
rake test:parallel                                              # the suite (JOBS=8 to pick a count)
rake test TEST=test/test_thing.rb                               # one file
rake test TEST=test/test_thing.rb TESTOPTS="--name=/pattern/"   # one test; -n /pat/ trips shell quoting
ruby -Itest test/test_thing.rb                                  # one file, no rake
```

The Wolfenstein port (`~/open_source/ruby-wolf3d`) has the same pair for its own suite, which
this one does not run and does not know about.

## Asserting what something COSTS

There is no cost estimator. There was one — a frame priced in scanlines against a budget — and
it is deleted, along with its weight table, its calibration tool and `rake cost:check`. So a
test that wants to say "this is more work than that" has two honest instruments, and picking
the wrong one is the mistake to avoid.

**What the build EMITTED**, for a claim about code that is a straight run of instructions:

```ruby
RubyGBA::IR::Backends::GBA.new.lower(program).bytesize
```

Right for "a tiny font emits less than the default one" or "resizing a sprite is more work
than turning it". Wrong wherever machinery is SHARED — a palette, a glyph routine — because
it lands wherever it is first needed, so the same `tint` reads as 172 bytes in one program and
52 in another.

**What the console really DID**, for anything about time:

```ruby
result = RubyGBA::Profiler.run(rom, frames: 30, picture: false)
result.idle_share        # how much of each frame was left over — the usual one
result.fps               # 60.0, or less when a pass does not fit in a frame
result.samples_per_frame # instructions a frame
```

It needs a ROM built through the DSL (or `rom_of`, which hands the build record over), because
a profile has to know where each routine ended up and that cannot be read back out of bytes.
`picture: false` skips the readings that look at the SCREEN rather than at where the time went
— whether the game tore, and whether it is losing half its drawing (`Flicker`). Both cost a bus
read per pixel; exactly one of them applies to any given game.

**Pick `idle_share` over `samples_per_frame`** for "is this faster". A pass too slow for one
frame spills into the next, so a slow build runs FEWER instructions per frame — counting those
reads backwards. And a program heavy enough to never sleep idles at 0.0 either way, so for one
of those compare `fps` instead.

**Tearing is measured too.** Whether a game CAN tear is a fact about the screen it chose, and
`BuildReport` says it. Whether one that can DOES is a race down the screen the drawing can win
even after overrunning, so a profile reads what happened (`RubyGBA::Tearing`) — except on a
screen with no framebuffer to read it off, where it says nothing rather than reporting no tear.

## The two backends you assert against

- **Reference interpreter** `RubyGBA::IR::Backends::Reference` — headless oracle, no
  emulator, in-process, deterministic. This is the source of truth.
- **Hardware** via `ruby-gba-emulator` → `RubyGBA::Verifier` — runs the real ROM, reads real
  pixels/audio. Fails loudly when the emulator is absent; it is required, not optional.

A feature isn't done until it's asserted on **both**. For anything with an
observable screen result, run the *same* program on each and assert identical
pixels — see `test/test_blit_clipping.rb` (`assert_same_pixels`) and the two
`*_at_the_left_edge` tests in `test/test_sprite_mover.rb` as the worked examples.

## Reference interpreter API

```ruby
i = Reference.new.run(program)          # returns self; 20 frames of a game loop by default
i = Reference.new.run(program, frames: 400)  # play this far in — every frame, however heavy
i.screen.pixel(x, y)               # colour at (x, y); nil if off-screen; 0 = unwritten (black)
i[:varname]                        # a variable's final value (0 if never written)
i.screen_mode                      # e.g. :bitmap
i.audio                            # the audio/register log
i.stopped_at_budget?               # true if it was still looping when cut off

Reference.new.hold(:left, :a).run(prog)              # buttons held for the whole run
Reference.new.input_each_frame { |f| [:left] }.run(prog)  # per-frame input; needed to observe `pressed` edges
Reference.new.frames_each_pass { |pass| 3 }.run(prog)     # say a pass ran late: 3 frames of catch-up
```

`frames_each_pass` is the one thing the interpreter cannot find out for itself — it has no
clock and is never late by construction — so a test says it. The block gives how many frames
each pass answered for, held between 1 and `IR::Frames::MOST` exactly as the console holds it.
That drives `once_a_frame` (the body runs that many times), a beat in frames, a one-shot's
counter, and the song playing (it moves on that many frames). It does **not** make the interpreter slow: timers still accrue a pass's worth, the
input script is still called once a pass, and `frames:` still counts passes. Use it to pin what
a program *means* when the console says it is late; use the emulator to find out whether it really is.

`frames:` is the stop condition, and every frame asked for is played however much work each
takes — so a test of a game that draws a whole view says `frames: 400` and gets 400. The step
budget behind it (`max_steps:`, a million by default) guards ONE frame, so a heavy frame can't
eat the frames after it; a frame that spends the whole budget never reached a vblank at all, and
raises rather than handing back a part-played run. **Do not pass `max_steps:` alongside
`frames:`** — the per-frame default has room to spare, and a hand-sized budget beside a frame
count is the old workaround for this bug. Reach for it only to run a program with no frames in it (an unpaced `frame_sync: :manual` loop),
where it becomes the whole-run budget and `stopped_at_budget?` reports it.

Screen default fill is `0` (black). For clip/overwrite tests, `clear_screen` to a
**distinct** background first so "clipped/absent" reads as that colour, and the
two backends agree on it.

## Hardware (emulator) API

**The emulator does real pixel work** — `assert_emulator_loads_rom` boots the ROM and reads the
actual rendered framebuffer. So such a test really runs (it does not skip), and a passing
`v.pixel_is?(...)` / `v.green?(...)` is a genuine hardware assertion, not a no-op. Don't
second-guess this: if a differential test (interpreter vs. the console) is green with
**0 skips**, the console really rendered those pixels. A fast wall-clock (these runs are quick)
is not evidence it was stubbed. Treat 0-skip runs as trustworthy cross-backend proof.


```ruby
include EmulatorSupport                    # from test/test_helper.rb
require_emulator!                          # ensure the emulator; fails loud if it isn't built

# lower an IR program to a ROM:
rom = RubyGBA::ROM.assemble(RubyGBA::IR::Backends::GBA.new.lower(prog),
                            title: "NAME", code: "BXYZ", maker: "01")

v = assert_emulator_loads_rom(rom, frames: 6, keys: KEY_LEFT)  # returns a Verifier
v.red?(x, y) / v.white? / v.blue? / v.green? / v.black?     # named-colour checks
v.pixel_is?(x, y, :red)                    # colour by name or 15-bit value
v.pixel_gba(x, y)                          # the raw 15-bit BGR555 (great in failure messages)
v.region_color?(x, y, w, h, :blue)
v.audio_energy / v.silent? / v.sound?      # "did the speaker do anything?"
```

`keys:` is an active-high `KEY_*` bitmask (OR them together), or a callable
`->(frame) { mask }` for input that changes over time. The emulator runs `frames:`
frames before you read pixels — give a static blit a couple, a moving sprite
enough to reach its resting position.

## Whole-screen differential testing

`test/differential.rb` compares the two backends over **all 38,400 pixels** instead
of a handful you picked. Reach for it when a feature's whole picture should match
(most drawing features), and keep the hand-picked assertions for the specific
values that document intent.

```ruby
include Differential                       # from test/differential.rb

assert_backends_agree(program, frames: 4)  # every pixel must match, or fail
backend_pictures(program, frames: 4)       # => [interpreter_pixels, console_pixels]
mismatched_pixels(oracle, console)         # => [[x, y, want, got], ...]
```

`frames:` is how many frames the **interpreter** plays; the console is run for the
matching number automatically. The two don't start counting at the same moment —
the console powers on and runs the ROM's setup before reaching the loop — so the
console run is longer by `Differential::BOOT_FRAMES` (bitmap 2, tiled 1). Those
are measured numbers, re-measured by a test, not guesses. A program that switches
display mode has no single offset and raises unless you pass `console_frames:`.

**The two are lined up on PASSES of the game loop, not on frames**, and the offset is
only there to give the console enough frames to make them. That matters because
`BOOT_FRAMES` was measured on a program with almost nothing to set up: a real tiled game
has a map to upload and a cast to declare, spills into a second frame, and is then one
pass behind for the whole run however fast the game itself is. A still picture can't show
that; a moving one shows it as a frame of drift, which reads exactly like a lowering bug.
So a program whose picture is a **finished** pass is compared at the passes the console
finished. That's a tiled or rotozoom screen (no framebuffer the game paints into — the
sprite table and scroll registers are written in one go right after the vblank) and a
tear-free bitmap one (two pages, the shown one finished). A single-buffered bitmap screen
can be caught half-drawn, so it keeps `BOOT_SLACK`'s one-pass tolerance and the
`OverBudget` refusal. Nothing here relaxes the comparison — it's still every pixel exact;
it only picks which moment is compared.

A failure prints the differing count, the first few coordinates with color names,
and a 40x20 map of *where* on screen they differ — enough to tell "the sprite is a
pixel off" from "everything below the map".

Use `backend_pictures` directly (not the assertion) to pin a **known** disagreement
that's filed but not fixed, so it stays visible without failing the build.

## Building the program under test — two routes

- **IR directly** (backend tests, cross-backend clip/pixel tests):
  `include RubyGBA::IR::Build`, then `program(screen(:bitmap), clear_screen(:white),
  bitmap(:s, width:, height:, pixels:, transparent:), blit(:s, x, y), halt)`.
  Use this when the lowering itself is under test — no DSL sugar in the way.

- **DSL** (asserting the surface behaves): `b = RubyGBA::Builder.new;
  b.instance_eval { screen :bitmap; ...; game_loop { ... } }; b.emit_pending_functions;
  b.program`. Or `RubyGBA.build("NAME", code:, maker:) { ... }` which returns a ROM
  (its `out:`/`err:` streams are DI'd — pass `StringIO` to assert warnings).

## Choosing test values

Make colours/positions *diagnostic*: a 4-pixel strip of red/green/blue/white
catches a wrong DMA source offset or transfer count (the wrong colour lands),
where a solid fill would only prove "something drew". For edge clipping, the
observable bug is a per-row DMA that **wraps** onto the neighbouring line — assert
the wrap target (e.g. `(239, y-1)`) is background.

## Guardrail tests

Assert the *friendly error* a misuse raises — its class and a key phrase, not the
exact wording (which is free to improve). See the guardrail tests for the shape.

## Gotchas

- Don't name a test helper `run` — it shadows `Minitest::Test#run`. The blit
  tests use `interpret`/`assert_same_pixels`/domain names instead.
- `rake test:parallel` runs everything; a single file is `ruby -Itest test/the_file.rb`.
- Integration tests **fail loudly** without the emulator rather than skipping — it is
  required, not optional, so a missing build is a real error and not a quiet pass with the
  coverage gutted.

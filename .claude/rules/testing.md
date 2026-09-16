---
paths:
  - "test/**/*.rb"
---

# Testing rules — `test/`

Helpers and patterns already established in this suite. Reach for these before
inventing new scaffolding. The *philosophy* (what to assert at which altitude,
the cross-backend rule) lives in `.claude/CLAUDE.md`; this file is the practical
how — the APIs and worked examples.

## Where a test file goes

`test/` mirrors the code it tests, the Ruby convention: a test sits in the
directory that matches the directory of the file whose behaviour it checks, and
keeps a name of its own.

| the test is about… | it lives in | e.g. |
|---|---|---|
| a file in `lib/ruby_gba/<dir>/` | `test/ruby_gba/<dir>/` | `lib/ruby_gba/audio/score.rb` → `test/ruby_gba/audio/` |
| a file at the top of `lib/ruby_gba/` | `test/ruby_gba/` | `cli.rb` → `test/ruby_gba/test_cli.rb` |
| a program in `examples/` | `test/examples/` | `examples/pong.rb` → `test/examples/test_pong_title.rb` |
| a script in `tools/` | `test/tools/` | `tools/emitted.rb` → `test/tools/test_emitted_tool.rb` |

It mirrors lib's DIRECTORIES, not its files. Most tests here build a whole game
and check what it does, so one test touches many files and one file is checked by
many tests; a folder per lib file would be a folder per test.

**Which file a test is about** is the one a person opens first when it fails:

- A test that builds a program through the DSL and checks what it does belongs to
  the builder file that DEFINES the verb — `test/ruby_gba/builder/`. Find it with
  `grep -n "def <verb>" lib/ruby_gba/builder/*.rb`. A test about a method on a
  handle rather than a verb (`sprite.face_angle`, `list.shift`) belongs to the dsl
  file that defines the method — `test/ruby_gba/dsl/`.
- A test that builds IR by hand and checks a backend belongs to that backend —
  `test/ruby_gba/ir/backends/gba/` and so on. It is the same behaviour at a lower
  altitude, so it lives where the lowering lives.
- A test of one guardrail — the friendly error for one known mistake — belongs to
  that guardrail: `test/ruby_gba/ir/guardrails/`.
- A test whose assertion is a number about the build or the run (bytes,
  instructions, frames, dropped sounds) belongs to the file that makes that
  number: usually a backend file, or `test/ruby_gba/diagnostics/` for the profiler
  and the reports.

It is never about which backend a test asserts against. A test that checks the
same behaviour on the headless interpreter and on the emulator is one test of one
thing, and it lives with the thing.

**One file, one `Minitest::Test` subclass.** A second class in a file hides from
the directory it sits in and from anyone grepping for a test name. Split it.

**No directory the lib does not have.** A new directory under `test/` is a new
directory under `lib/` first. That is what stops the tree growing a folder per
feature.

The shared helpers — `test_helper.rb`, `differential.rb`, `emulator_blend.rb`,
`conformance_fixture.rb` — stay at `test/`, and are loaded **by bare name**
(`require "differential"`). That works from any depth because the Rakefile puts
`test` on the load path. Never `require_relative` them: that one breaks the
moment a file moves.

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
rake test TEST=test/ruby_gba/dsl/test_thing.rb                  # one file
rake test TEST=test/ruby_gba/dsl/test_thing.rb TESTOPTS="--name=/pattern/"  # one test; -n /pat/ trips shell quoting
ruby -Itest test/ruby_gba/dsl/test_thing.rb                     # one file, no rake
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
result = RubyGBA::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
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
even after overrunning, so a profile reads what happened (`RubyGBA::Diagnostics::Tearing`) — except on a
screen with no framebuffer to read it off, where it says nothing rather than reporting no tear.

## The two backends you assert against

- **Reference interpreter** `RubyGBA::IR::Backends::Reference` — headless oracle, no
  emulator, in-process, deterministic. This is the source of truth.
- **Hardware** via `ruby-gba-emulator` → `RubyGBA::Diagnostics::Verifier` — runs the real ROM, reads real
  pixels/audio. Fails loudly when the emulator is absent; it is required, not optional.

A feature isn't done until it's asserted on **both**. For anything with an
observable screen result, run the *same* program on each and assert identical
pixels — see `test/ruby_gba/builder/test_blit_clipping.rb` (`assert_same_pixels`)
and the two `*_at_the_left_edge` tests in
`test/ruby_gba/dsl/test_sprite_mover.rb` as the worked examples.

## Which frame's numbers the picture was drawn from

**Read a pixel and a variable at the same moment and you are not always reading the same
frame.** Which of the two you are looking at depends on who drew it, and it is the same answer
on both backends:

- **What the program draws** — `pixel`, `fill_rect`, `draw_rect_at`, `blit`, bitmap
  `draw_text` — is in the picture a test reads for the pass that drew it, because it writes
  the pixels itself and the test is reading those pixels. The picture and the variable agree.
  (What a *player* sees can still lag or tear, since those writes happen while the frame is
  being scanned out — that is the separate question `RubyGBA::Diagnostics::Tearing` answers.)
- **What the framework draws for you** — a `sprite`, a tiled `draw_text`/`draw_number` glyph,
  a background's scroll position — is painted in the gap *before the next frame*, from the
  variables as they stand then. So the picture shows the value from the pass **before** the
  one whose variables you are reading: `v.var(:n)` is 5 while the sprite is standing where 4
  put it.

That is not a cost of the interpreter or a quirk of the emulator. A position decided while a
frame is being drawn cannot appear in that frame — the frame was already on its way to the
screen — so a game runs this way on real hardware too, and the one frame is not something to
design away. Rotating the loop does not move it: the sequence of "body, gap, paint, body, gap,
paint" is the same however you spell the loop.

**What to do about it in a test:** run one frame further and read the picture then, or read
the variable one frame earlier. `test/ruby_gba/ir/test_frame_pairing.rb` pins both halves of this on both
backends, so if either ever stops behaving this way that file fails rather than a game's suite.

It only bites a test that pairs the two — "is the sprite drawn where the program put it",
"is the HUD showing the score the program set". A test that reads only pixels, or only
variables, never meets it.

## Reference interpreter API

```ruby
i = Reference.new.run(program)          # returns self; 20 frames of a game loop by default
i = Reference.new.run(program, frames: 400)  # play this far in — every frame, however heavy
i.screen.pixel(x, y)               # colour at (x, y); nil if off-screen; 0 = unwritten (black)
i[:varname]                        # a variable's final value (0 if never written)
i.screen_mode                      # e.g. :bitmap
i.audio                            # the audio/register log
i.stopped_at_budget?               # true if it was still looping when cut off

i.sprites(:hero)                   # the rows it drew for that named sprite
i.sprites                          # everything it drew, each saying whose it is

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

**Ask the oracle which sprite is which rather than hunting for it in the fake screen.**
`i.sprites` is the interpreter's half of `v.sprites` below, and it answers the same questions
pixels cannot: it tells a sprite the game switched off from one drawn in the backdrop colour,
from one behind a background, from one a pixel off the edge. Each row is a `DrawnSprite`,
reading `row.name`, `.x`, `.y` and `.picture` — `picture` being the one of its pictures the pose
selector picked, said as the name the author drew rather than as a number counting into the set.
The first three are named and mean the same as on a `SpriteRow` off the console, so a test
comparing the two backends reads both the same way (and `row[:x]` works on neither). A sprite
that is not being drawn is absent, every live slot of a `pool` comes back under the pool's name,
and a row the author named nothing for (a letter of tiled text) has a nil `name`. There is no slot number
here and that is deliberate: the console has 128 places to put a sprite in and the interpreter
has none, and naming a place was the thing worth getting rid of. Prefer this to building a ROM
whenever the question is where something was drawn.

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
rom = RubyGBA::Cartridge::ROM.assemble(RubyGBA::IR::Backends::GBA.new.lower(prog), title: "NAME")

v = assert_emulator_loads_rom(rom, frames: 6, keys: KEY_LEFT)  # returns a Verifier
v.red?(x, y) / v.white? / v.blue? / v.green? / v.black?     # named-colour checks
v.pixel_is?(x, y, :red)                    # colour by name or 15-bit value
v.pixel_gba(x, y)                          # the raw 15-bit BGR555 (great in failure messages)
v.region_color?(x, y, w, h, :blue)
v.audio_energy / v.silent? / v.sound?      # "did the speaker do anything?"

v.sprites(:hero)                           # the console's own rows for that named sprite
v.sprites                                  # every row being drawn, each saying whose it is

v.step                                     # play one more frame; everything after reads it
v.step(4, keys: KEY_RIGHT)                 # ...or four, holding a button while they run

v.var(:hurt)                               # a variable the program computed, by name (vars: needed)
v.mem32(address) / v.mem16 / v.mem8        # the raw word/halfword/byte at an address

v.palette(:sprites, row[:palette])         # the sixteen colours that sprite row is wearing
v.palette                                  # the whole table: 512, backgrounds first then sprites
v.showing(only: :sprites) { v.step; ... }  # draw the picture without some of it
v.hearing(without: :wave) { v.step(40); ... }  # mix the sound without some of it
v.layers / v.channels                      # the names those two can be given
```

**One reader over one cartridge.** Everything above comes off the same Verifier on purpose —
holding a second reader over the same ROM is two readings of one frame that can disagree, and
they do: the emulator's own low-level handle (`RubyGBA::Diagnostics::Emulator.probe`) reports where a
sprite's tiles were PUT rather than where its picture starts. Reach for that handle only for
what the Verifier deliberately does not do (cost and timing, watching an address change,
profiling); never for a second reading of something the Verifier already answers.

`showing` and `hearing` change the **console**, not the reading, so the block must `v.step`
before it reads anything or it reads the picture from before the layer went. The layers and
voices go back as they were when the block ends. Taking a voice out from under a note it is
holding is a cut rather than a rest — the mix steps and drifts back over about half a second —
so step well past that before asking whether it went quiet. The sound readers cover the whole
run, so inside a block use `audio_energy_by_frame.last(n)` rather than the total.

`v.var` is **the number the program counted to**, so a count taken below nothing reads below
nothing and matches `i[:hurt]` for the same frame. A variable here is a signed whole number by
definition, so nothing has to be asked or guessed; `v.mem32` stays the raw word, because an
address holds whatever is at it and a hardware register is not a program's whole number. Worth
knowing only because the wrong one is not obviously wrong: the raw word says four billion where
the program says minus one, and `count > 0` then reads true for a count of minus one.

**Ask the console where a sprite is rather than hunting for it in the picture.** `v.sprites`
reads the table the console composes from, so it answers what pixels cannot: it tells a hidden
sprite from one drawn in the backdrop colour, from one behind a background, from one a pixel
off the edge. Each row reads `row.name`, `.x`, `.y`, `.slot`, `.tile`, `.palette`,
`.color_count`, `.colors`, `.priority`, `.shape`, `.size`, `.mirrored_across`, `.mirrored_down`,
`.turned`, `.piece_x`, `.piece_y`, and a sprite the game switched off is simply absent.
**A row is a `SpriteRow`, not a Hash, and `row[:x]` does not work** — deliberately: as a Hash a
field name that was slightly wrong read back as nothing, so a test asserting on one passed, or
failed for a reason that was not the one it looked like. Written as a method a wrong name cannot
be run at all. `x`/`y` are **where the picture starts** — the corner of the canvas the
art was drawn on, which is where the game put the sprite, and the same number `i.sprites` gives.
That is not the number the console carries: a pose is stored trimmed to what it draws and the
sprite stands that much further along, and a pose drawn backwards is trimmed from the other side
and stands a different amount again — so the console's own number is right facing one way and
out by up to a canvas facing the other. `piece_x`/`piece_y` still carry it for a test that
wants the hardware fact. `colors` is **the colours it is wearing**, ready to compare against —
no group number and no arithmetic. A picture is stored one of two ways, drawing from a group of
sixteen colours or from all 256, and `color_count` says which; `colors` is already the right
run either way, which `v.palette(:sprites, row.palette)` is not (that one is meaningless for a
picture of the second kind). **Name it and only its rows come back** — never identify one by a slot number (a magic
number that moves the day the game declares something earlier), by position (which needs the
game to keep its own position in a variable, and is a pixel or two out exactly while the thing
is moving), or by which colours it draws from (no use at all once they are being swapped). A
picture too big for one of the console's sprites is several rows with the same name, and every
live slot of a `pool` comes back under the pool's name. Rows the author named nothing for — a
letter of tiled text — have a nil `:name`. Needs a ROM assembled with its build record, which
`assemble_rom` and `RubyGBA.build` both do; `rom.built.sprite_slots` is the raw map.

`keys:` is an active-high `KEY_*` bitmask (OR them together), or a callable
`->(frame) { mask }` for input that changes over time. The emulator runs `frames:`
frames before you read pixels — give a static blit a couple, a moving sprite
enough to reach its resting position.

**`v.step` when the question is about something HAPPENING**, not about where it ended up:
which picture is showing on each frame of a knockback, which colours a thing is drawn in while
it cannot be hit, how many frames a flash lasts, whether something vanishes and comes back. It
plays on from where the run left off, and everything read afterwards — pixels, `v.var`,
`v.sprites`, `v.palette` — is the frame it stopped on. See "one reader over one cartridge"
above for why this and not a second handle.

**How many times round the game loop the console got**, which is not the frame count:

```ruby
v = assert_emulator_loads_rom(rom, frames: 20, count_passes: true)
v.passes                                   # passes FINISHED; nil for a program with no loop
```

The console runs the loop once per frame it has TIME for, so a game whose pass does not fit in
a frame plays less game per frame than one that does — which is why lining a console run up
against an interpreter run is done on passes and never on frames (see the differential below).
It is counted by watching for the loop's own instructions while the cartridge runs, so the
cartridge measured is the cartridge that ships; it is off by default because it costs a little
(about a twelfth again on a cartridge that sleeps most of its frame, a bit over a third on one
that uses all of it), and nothing pays for it unless it asks.

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
  b.program`. Or `RubyGBA.build("NAME") { ... }` which returns a ROM
  (its `out:`/`err:` streams are DI'd — pass `StringIO` to assert warnings).
  **Don't write a `code:`** — a made-up four-character cartridge code lands on a real
  cartridge's often enough that thirteen in this suite did, and one that does is now a
  build error. Left out, it's worked out from the title.

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

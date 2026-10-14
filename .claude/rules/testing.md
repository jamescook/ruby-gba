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
- A test of a command belongs to the file that does the command's work, which is
  not always `cli.rb`. `ruby-gba play` and `ruby-gba compare` are declared in
  `cli.rb` and done by `lib/ruby_gba/playthroughs/command_line.rb`, so their tests
  are in `test/ruby_gba/playthroughs/` with the rest of that module's — which is
  what lets `rake test:playthroughs` be one folder. They still run the real
  command in a process of its own, so what `cli.rb` declares is tested with it.

It is never about which backend a test asserts against. A test that checks the
same behaviour on the headless interpreter and on the emulator is one test of one
thing, and it lives with the thing.

**One file, one `Minitest::Test` subclass.** A second class in a file hides from
the directory it sits in and from anyone grepping for a test name. Split it.

**No directory the lib does not have.** A new directory under `test/` is a new
directory under `lib/` first. That is what stops the tree growing a folder per
feature. The one exception mirrors a directory too, just not lib's:
`test/ruby_gba/ir/backends/native/examples/` holds the native lowering's checks of each
program in `examples/` (see "Running a file on the native lowering too").

The shared helpers — `test_helper.rb`, `differential.rb`, `emulator_blend.rb`,
`mixed_sound.rb`, `conformance_fixture.rb` — stay at `test/`, and are loaded **by bare name**
(`require "differential"`). That works from any depth because the Rakefile puts
`test` on the load path. Never `require_relative` them: that one breaks the
moment a file moves.

## How a test file starts

**One require, nothing else:**

```ruby
# frozen_string_literal: true

require "test_helper"

class TestThing < Minitest::Test
  runs_on :reference   # or `runs_on :reference, :native`: every class says (see below)

  def test_it_does_the_thing
    ...
  end
end
```

`test_helper` pulls in minitest and the library, and hands every test these
names and helpers with nothing to declare:

- `Reference` (the oracle backend), `SaveImage` (a cartridge's save memory, handed to `Reference.new(save:)` and the Verifier), `GBA` (the ROM lowering), `Builder`, `Color`, `ROM`
- `EmulatorSupport` — `assert_emulator_loads_rom`, `assemble_rom`, `require_emulator!`

It does that by reopening `Minitest::Test` and including them — the Minitest
equivalent of RSpec's `config.include`. **Do not re-declare those constants in a
test file.** If a file needs one of those names for something else, just declare
it: a constant in the file wins over the shared one (see `test_cost_printer.rb`,
which points `Color` at the printer's palette).

Narrower helpers stay **opt-in**, so their names appear only where used:
`include Differential`, `include CostArith`, `include RubyGBA::IR::Build`.

Running them. **The suite is `rake test`** — one process, with each test given a core of its
own (see "Ractors" below). `TEST=` names one file, `TESTOPTS=` one test:

```bash
rake test                                                       # the suite
rake test TEST=test/ruby_gba/dsl/test_thing.rb                  # one file
rake test TEST=test/ruby_gba/dsl/test_thing.rb TESTOPTS="--name=/pattern/"  # one test; -n /pat/ trips shell quoting
rake test:playthroughs                                          # one module: every test in test/ruby_gba/playthroughs/
bundle exec ruby -Itest test/ruby_gba/dsl/test_thing.rb         # one file, no rake (plain minitest)
```

The last one needs `bundle exec`, because the runner is a gem.

The Wolfenstein port (`~/open_source/ruby-wolf3d`) has a suite of its own, which this one does
not run and does not know about.

## Ractors — fix what the runner reports

`rake test` runs the suite through **minitest-ractor**
(`github.com/jamescook/minitest-ractor`, taken from git until it is released). It gives each
test a Ractor of its own — Ruby's way of using several cores in one process — and reports
every test that reached state the whole process shares.

**Those findings are bugs, not noise, and they are not the runner being fussy.** A global, a
class variable, a module's own registry, a fixture one test can change and the next reads
changed: each is an order-dependent fault that simply stays invisible while everything runs
one after another. Make the code Ractor-friendly rather than silencing the report.

- something read from a global or a class variable while the test runs → read it once when
  the file loads, into a constant
- a module's registry, or a lazy `@thing ||= …` cache → keep one per Ractor:
  `Ractor.current[:key] ||= …`, or `Ractor.store_if_absent(:key) { … }`
- a fixture in a constant → nothing to do. `test_helper.rb` freezes every constant a test
  class declares, all the way down, the moment it is declared.

The one honest way out is a test that **changes the whole process on purpose** — registering a
font or a guardrail, swapping a library method for a stub, declaring a class, asserting about
the process's own output — or one that **starts a child process**, which Ruby cannot do from
inside a Ractor (the spawn waits for ever; `test/tools/test_rakefile.rb` does it — a native
test does too, and runs only on the native run, which uses processes instead). That class says `runs_on_the_main_ractor!` at the top, **with a line
saying why**, and runs before the pool starts. It is not somewhere to park a test nobody has
looked at.

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

## Running a file on the native lowering too

The native backend (`Backends::Native`, the game as C) trails the two above, and it is checked
with the tests that already exist rather than with copies of them. A run of the suite tests ONE
lowering (`test/support/suites.rb`): `rake test` the interpreter, `rake test:native` the C. A
class runs only on the lowerings it names.

**Every test class has to name them**, on a line straight after its `class` line:

```ruby
runs_on :reference             # only the interpreter and the cartridge play these
runs_on :reference, :native    # the game built as C plays them too
runs_on :native                # the native lowering's own tests
```

A class with tests that says nothing stops the run before a test is played, naming the class
and its file. Saying nothing used to mean "the interpreter alone", and that read the same
whether the native lowering could not play the tests yet or nobody had looked — so a new test
file starts with `runs_on :reference` when native has no part in what it tests (the cartridge's
machine code, a guardrail's wording, the emulator), and with both when it plays a game native
can build. A native run ends by counting the classes each way.

**An example that becomes buildable is not left behind.** `ruby tools/native_examples.rb` lists
the examples the native lowering can write as C today and what each of the others is refused
for. `test_native_examples.rb` fails when one that builds has no recorded run
(`native/examples/test_<example>_picture.rb`), or when a test file in `test/examples/` whose
examples all build still plays them on the interpreter by name (`Reference.new`), or asks for
`game_player` in a class that does not name both lowerings. A file whose tests are all of the
cartridge, in the emulator, has nothing for the game as C to play and stays
`runs_on :reference`. So when a native feature lands, run the tool: every example it newly
lists is work the next native run will ask for.

A class inherits what the class above it said, so a subclass of a test class that has said
need not say again.

Opting a file in is two edits, and no assertion changes:

```ruby
class TestPongScoring < Minitest::Test
  runs_on :reference, :native        # this class's tests are true of both

  def pong_line_at(frames)
    i = game_player                  # was Reference.new; takes save: the same way
    i.input_each_frame { |f| f < 3 ? [:a] : [] }
    i.run(Pong.program, frames: frames)
    ...
```

On a `rake test` run `game_player` IS `Reference.new`. On a native run it is a
`CheckedNativeRun`: the game built as C and driven through the same calls (`hold`,
`input_each_frame`, `each_vblank`, `run`, `[]`, `vars`, `screen.pixel`, `screen.to_a`,
`screen.stored_pixel`, `screen.camera_x` and `screen.camera_y`, `sprites`, `list`, `pool`,
`game_state`, `buffered`, `audio` so far, growing with each native slice), and then the same
buttons replayed on the interpreter, failing at the first frame where any variable, any list or
pool field, any pixel, the sound log or the sprites drawn differ. So an opted-in file's own
checks are backed by a whole-picture comparison on every frame. **A game that saves is played both ways from the same save memory**:
`game_player(save: image)` hands the game as C the image's bytes as a .sav file, puts what the
run left back into the image (so the SAME image handed to two runs is a power cycle, as it is
for the interpreter), replays on the interpreter from a copy taken first, and fails if the two
end with different bytes. A cut waiting on the image (`cut_power_after`) cuts both at the same
step. A block given to `each_vblank` watches the game as C, at each frame
boundary as the run goes, and an input script can read the picture as well as the variables. A
run by step budget
(`run(program, max_steps: 400)`) plays there too, with nothing to change: a budget is the
interpreter's own measure, and it stops a game on a frame boundary, so the interpreter is asked
how many frames fit in the budget and the C plays that many. The sound log is the interpreter's
words for what was played. The C keeps that log, and plays the sound, for songs — parts on the
square wave, the wave voice, the noise voice and on recordings, named or picked from a list, a
song that plays once, and the music volume — for beeps, `wave`, `stop_wave` and `noise`, and for
the game's own recordings. What the mixer makes is compared slice for slice on every run
(`mixed_sound`, `active_samples`, `peak_voices`, `volume_of`, `level_of` and `sound_drops`
answer). A game with a sound effect list is refused by name when it is built.

Opt a file in once native can play its games, and in chunks that go with the native slice that
made them pass. What the native player cannot answer yet raises `HeadlessRun::CannotAnswer`
naming the call — the file came too early, or that one test wants `skip_on_native "why"` at
its top, which does nothing on the interpreter's run. A test that reaches
for the emulator (`require_emulator!`, `assert_emulator_loads_rom`, or the console's picture
through `Differential#backend_pictures`) skips itself on a native
run, since the cartridge is `rake test`'s; any check on the game before it has already run.
Every skip says why, and a native run ends with the skips counted by reason.

**`assert_backends_agree` does not skip there.** On `rake test` it asks whether the console draws
what the interpreter draws. On a native run the same line asks that of the game as C: the
program is played as C with the same buttons held and compared with the interpreter on every
frame (it hands back the `CheckedNativeRun`). So a file full of whole-picture comparisons is
worth opting in for those alone, with no line of it changed.

**A whole example on native gets files of its own**, beside the opted-in tests in
`test/examples/`, under `test/ruby_gba/ir/backends/native/examples/`: `test_<game>_picture.rb`
plays a recorded run of buttons and compares every variable, every pixel and the sound log with
the interpreter's on every frame, and `test_<game>_sounds.rb` compares what comes out of the
speaker with the cartridge's (below). `test_pong_*.rb` and `test_pacman_*.rb` are the worked
examples. A small made-up program for one feature goes in `test_native_picture.rb` or
`test_native_tones.rb` instead, and never requires an example.

**The sound itself** — what would come out of a speaker — is checked against the cartridge's own,
in the emulator, with one shared helper for any game (`test/sound_comparison.rb`):

```ruby
include SoundComparison
assert_native_sounds_like_the_console(program, frames: 300, buttons: { 3 => [:a], 4 => [:a] })
```

It plays the game both ways one voice at a time and compares every frame: how loud the voice is,
its pitch, and how thin or full its tone. It listens to the two square voices unless told which
(`voices: %i[square1 wave noise]`), and every voice it is told has to be heard. The noise voice
is a hiss and has no pitch, so in its place the helper compares how bright the hiss is — how
often it changes — and a test of the pattern itself reads which way the voice stands on each
step of a slow one (`Heard#runs`, in `test_native_tones.rb`). The emulator is the answer key
there and not the thing under test, so the helper asks it directly rather than through
`require_emulator!`. Its tolerances and the reason for each are written at the top of the file. A small made-up program
goes in `test/ruby_gba/ir/backends/native/test_native_tones.rb`; a whole example's sound goes in
a file of its own under `test/ruby_gba/ir/backends/native/examples/`
(`test_pong_sounds.rb`). The windowless program has no speaker, so for these it writes its sound
to a temporary file (`--sound-out`) that the helper reads back; a game played in its window
writes none.

**The console starts its game a frame or two after the desktop build**, and the helper lines
the two up on when each first makes a sound (trying a frame either side of that as well, and
keeping whichever agrees best). What it cannot line up is a button that lands on a
different pass of the game in each: walk a character for frames 3 to 30 while something chases
it, and the chaser is two passes further on in one than the other, so it is caught a frame apart
and every sound after that is a frame out. That reads exactly like a fault in the sound. Hold
such a button from frame 1 until what it does has stopped mattering — the character is against
a wall, the menu has moved on (`test_pacman_sounds.rb`).

**The window's own input** is tested by pressing keys through SDL (`--scripted-keys`, in
`test_native_desktop.rb`, under `SDL=1`): each is a real key event, onto the gamepad the keyboard
is, round the window's frame loop. Feeding buttons to the windowless program goes round all of
that, so a fault in how the window reads a key shows only there.

**The window's save file** is tested there too, on a game of a few lines that keeps a count:
that the file holds the bytes the interpreter's save memory does, is read before the game
starts, is written while the game is still running, and lands in a folder named for the game
among the files of whoever plays. A desktop build started with `--save-file PATH` keeps its save
there in place of that folder, which is how a test (or a person trying something) keeps out of
real saves. WHEN the window writes the file is plain counting in `runtime/rg_save.c`, and is
tested as that with no window (`test_native_save_file.rb`). Small made-up programs that save
go in `test_native_saves.rb`.

**How evenly the window shows its pictures** cannot be seen by a test, and a stutter is exactly
that. A desktop build started with `--frame-times` says at its end, on the error stream, what
paced its frames (the monitor, or the console's clock), how far apart its pictures were handed
to the display, which gaps were more than two milliseconds from the middle one, and whether any
sound was thrown away or ran dry. A stutter is a clump of uneven gaps that comes round every few
seconds; scattered single ones are the computer being busy. `--refresh-rate 144` makes it
choose its pacing as for a monitor of that rate, so the code each kind of monitor gets can be
run on the one there is. It is only the choice that is pretended: the real monitor still
refreshes at its own rate, so `--refresh-rate 120` on a 60Hz monitor shows each picture for two
of its refreshes and plays the game at half speed. The rule that picks the pacing from a monitor's rate, and the limit that
stands behind the monitor while the window is hidden, are plain arithmetic in
`runtime/rg_pacing.h` and tested as that (`test_native_pacing.rb`).

**An editor's complaints about the runtime's C are not the build's.** A C checker in an editor
(or the one that reports after an edit here) reads `lib/ruby_gba/ir/backends/native/runtime/`
on its own. Every native build — a test's, or a game built for the desktop — keeps a
`compile_flags.txt` above that folder holding the build's own flags and header folders
(`Native::Zig.checker_flags`), so the checker holds the code to what the build does and finds
SDL's headers, and nobody runs anything to get it. What that cannot cure: after a header is edited
the checker can go on reading it at its old positions and report nonsense, such as "invalid
suffix on integer constant" on a line that only names a number the header defines. Ask the
compiler itself before believing it, which takes a few seconds:
`rake test:native TEST=test/ruby_gba/ir/backends/native/test_native_checker_flags.rb`.

**A native run plays its tests in several processes, not Ractors** (a Ractor cannot start the
child processes a native test needs). `tools/parallel_test.rb` starts `TEST_PROCESSES` of them —
as many as `rake test` has workers unless told otherwise — and hands them one test at a time, so
one slow file never decides how long a run takes, even a run of that file alone. Each process
sends its results back and the run prints them as one report: the same totals, failures, skips
by reason and class counts one process would print. A process that dies under a test costs that
test, reported as an error saying how it died, and a new one takes its place. Not threads: a
native test is nearly all Ruby work, and threads take turns at that, so they bought next to
nothing. A native run never checks for shared state — `rake test` runs the same file and does.
The native backend's own tests (`test/ruby_gba/ir/backends/native/`) say `runs_on :native`
alone, and `rake test` loads them and runs nothing in them.

**A whole run of either suite has the machine to itself.** `rake test` and `rake test:native`
each take one lock for the whole machine (`tools/suite_lock.rb`) before they start, so the
second waits for the first and says which run it is waiting for. A run of one file (`TEST=`)
does not take it.

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
i.list(:trail)                     # a list's items now, oldest first, as an Array
i.pool(:guard, :x)                 # a pool field, one entry per slot: the value, or nil where the slot is free
i.game_state                       # { vars:, lists:, pools: } — all of the game's own state; compare two with ==
i.screen_mode                      # e.g. :bitmap
i.audio                            # the audio/register log
i.mixed_sound                      # every frame's slice of mixed recordings, the bytes the cartridge's mixer writes
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
counter, the song playing (it moves on that many frames), a recording the game plays (it is
that many frames further through, so it ends as many frames in as it lasts), and the buttons,
which are read on each of those frames — `input_each_frame` is called once per frame the screen shows, numbered
on the screen, so a tap can start and end inside one slow pass. It does **not** make the
interpreter slow: timers still accrue a pass's worth, and `frames:` still counts passes. Use it to pin what
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

**A program with a game loop shows white until its first frame is set up**, on both backends:
the picture is held off while the game sets up, which is the console's own forced blank. So
`run(program, frames: 0)` reads white everywhere for such a program, and so does the console
for however many frames setting up takes. Read from `frames: 1`, or on the console step until
the picture stops being white. A program with no loop is shown as it is drawn.

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

v.only_color                               # the one colour every pixel is, or nil for a picture
v.brightness                               # every pixel's red, green and blue added up, each 0..31
v.frame_colors                             # the whole screen as one string, two bytes a pixel
v.frame_gba                                # ...and as a list of 15-bit numbers, to look pixels up in
v.same_picture_as?(other)                  # another reader, or a `v.picture` kept from earlier
v.difference_from(other)                   # { count:, box: [x, y, w, h], at: [x, y], colors: [here, there] } or nil

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

**The questions about the whole screen are cheap, and the list is the dear one.** The emulator
answers `only_color`, `brightness`, `frame_colors`, `same_picture_as?` and `difference_from` in
one pass over the picture, so a test can ask one on every frame of a run of thousands and the
run takes about what it took. `frame_gba` makes 38,400 numbers and costs several frames' worth
of time, so keep it for looking pixels up in: to keep a still, hash one, or ask whether the
screen changed, use `frame_colors` or `same_picture_as?`. All of them answer at the precision a
console shows, five bits a channel. The emulator keeps eight, and works a colour the display
brightened, darkened or mixed out at all eight, so it can hold one five-bit colour as two
different numbers and two readers showing one picture can hold different bytes. `all_black?` is
the one that asks the emulator's eight, as it always did: a screen darkened to almost nothing is
black to `only_color` and `black?(x, y)` a frame before it is black to `all_black?`.

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

**The sound of a long run is not all in memory, and nothing that reads it can tell.** A reader
holds a minute of play at most. Once it holds more, it writes all of it to the end of a scratch
file in the machine's temporary files and starts again from nothing; the file is removed when
the reader is collected, or when the program ends. Every sound reader still answers for the
whole run. A run of a minute or less writes no file, which is nearly every test here. The
energy readers (`audio_energy`, `audio_energy_by_frame`, `silent?`, `sound?`) can be asked after
every frame of a long run: how loud each frame was is worked out once and kept, so the only
sound an asking reads is the frames played since the last one, and
`v.step.audio_energy_by_frame.last` is how loud that frame was. `audio_samples` is the one to
ask once: it hands back every sample at once, read from the file each time, which for a long
run is all of it in memory after all. To hold another number of frames, or to put the file
somewhere else (a machine can keep its temporary files in memory), hand the reader
its sound: `Verifier.new(rom, sound: RubyGBA::Diagnostics::RecordedSound.new(frames_in_memory:
600, folder: "scratch"))`.

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
**A sprite the game put off the screen is not absent**: it reads at its own place wherever the
console's table can say it — up to 96 rows above the screen or 32 below, and well past either
side — and just past the bottom or right edge when the table cannot, because the framework
stands it there so that it does not come round onto the screen. That is row 160 or column 240
for a picture stored as drawn, and a little less for a pose stored trimmed, since `y`/`x` take
the trim back off. A sprite 64 pixels tall that turns or resizes, stood there, reads `turned`
false: it is written as a plain sprite there, because its turned box would come round.
`i.sprites` gives the game's own place however far off that is, so a test that compares the two
for a sprite parked far away compares them while it is near.
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
is compared at the console's passes when the console finished MORE than the frames asked
for — the bitmap boot offset leaves room for one, and a game that keeps up stops between
two passes, so its picture is the last pass painted. Below the frame count it can be caught
half-drawn, so there it keeps `BOOT_SLACK`'s one-pass tolerance and the `OverBudget`
refusal. Nothing here relaxes the comparison — it's still every pixel exact;
it only picks which moment is compared.

A failure prints the differing count, the first few coordinates with color names,
and a 40x20 map of *where* on screen they differ — enough to tell "the sprite is a
pixel off" from "everything below the map".

Use `backend_pictures` directly (not the assertion) to pin a **known** disagreement
that's filed but not fixed, so it stays visible without failing the build.

## Byte-for-byte sound

`test/mixed_sound.rb` does for recorded sound what `differential.rb` does for the
picture: the interpreter works out every byte the cartridge's mixer writes
(`i.mixed_sound`, one slice a frame), and this holds the two to each other.

```ruby
include MixedSound                         # from test/mixed_sound.rb

assert_mixes_agree(program, frames: 24)    # every byte of every slice must match
assert_mixes_agree(program, frames: 150, presses: { 5 => [:up], 60 => [:a] }, at_least: 60)
console_mixes(program, 30)                 # the console's slices, newest after each frame
```

Each backend's list is taken from its **first slice with any sound in it**, because the
console spends frames setting up before the game's first pass. So what it cannot see is
the two a frame apart on everything; what it does see is one sound landing a frame late
against another — which is why a test of timing plays two (a tune, and a sound the game
starts in its loop). It reads only recorded sound: the console's square, wave and noise
voices never pass through memory.

## Building the program under test — two routes

- **IR directly** (backend tests, cross-backend clip/pixel tests):
  `include RubyGBA::IR::Build`, then `program(screen(:bitmap), clear_screen(:white),
  bitmap(:s, width:, height:, pixels:, transparent:), blit(:s, x, y), halt)`.
  Use this when the lowering itself is under test — no DSL sugar in the way.

- **DSL** (asserting the surface behaves): `b = RubyGBA::Builder.new;
  b.instance_eval { screen :bitmap; ...; game_loop { ... } }; b.finalize_program;
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
- `rake test` runs everything; a single file is `rake test TEST=test/the_file.rb`.
- Integration tests **fail loudly** without the emulator rather than skipping — it is
  required, not optional, so a missing build is a real error and not a quiet pass with the
  coverage gutted. The one exception is a native run (`rake test:native`), which is there to
  test the game as C: there they skip, saying so, and `rake test` still runs them every time.

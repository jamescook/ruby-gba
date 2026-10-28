---
paths:
  - "test/**/*.rb"
---

# Testing rules — `test/`

The rules every test here follows. What to assert at which altitude, and the cross-backend rule,
are in `.claude/CLAUDE.md`. The APIs and the long stories are in `.claude/testing/`; read the one
you need before writing a test that uses it:

| file | what it holds |
|---|---|
| `interpreter.md` | the reference interpreter: reading pixels, variables, lists, pools, sprites; input; late passes; the step budget |
| `emulator.md` | the emulator's reader: pixels, whole-screen questions, sprites, palettes, sound, stepping, counting passes |
| `differential.md` | interpreter against console: every pixel (`assert_backends_agree`), every byte of mixed sound |
| `lowerings.md` | the native, JavaScript and Game Boy Color runs: what `game_player` is there, what it compares, saves, examples, `test/advance/`, the library's test kit |
| `native-sound.md` | the game as C's speaker against the cartridge's, and the frame-apart trap |
| `desktop.md` | the desktop window: keys, Retina, the save file, frame pacing, the editor's C checker |
| `runs.md` | rake commands, which run a change needs, the machine-wide lock, worktrees, the native run's processes |
| `costs.md` | asserting what something costs: bytes emitted, or the profiler's idle share and fps |

## Where a test file goes

`test/` mirrors lib's directories (not its files): a test of `lib/vblank/audio/score.rb` is in
`test/vblank/audio/`, of `cli.rb` in `test/vblank/`, of an example in `test/examples/` (or
`test/advance/examples/` for a game for the Advance alone), of a tool in `test/tools/`. A new
directory under `test/` needs one under `lib/` first. The exceptions are
`test/vblank/ir/backends/native/examples/` and `test/vblank/ir/backends/gbc/examples/`, which
mirror `examples/`, and `test/advance/`, which mirrors `test/` (below).

A test belongs to the file a person opens first when it fails:

- A DSL program checked for what it does → the builder file that defines the verb,
  `test/vblank/builder/` (`grep -n "def <verb>" lib/vblank/builder/*.rb`). A method on a
  handle (`sprite.face_angle`, `list.shift`) → the dsl file defining it, `test/vblank/dsl/`.
- Hand-built IR checked on one backend → that backend's folder.
- One guardrail's friendly error → `test/vblank/ir/guardrails/`.
- A number about the build or the run (bytes, frames, dropped sounds) → the file that makes the
  number, usually a backend or `test/vblank/diagnostics/`.
- A command → the file that does its work. `vblank play` and `compare` are done by
  `lib/vblank/playthroughs/command_line.rb`, so their tests are in `test/vblank/playthroughs/`.

Never by which backend a test asserts against: one behaviour checked on the interpreter and the
emulator is one test, with the thing.

**One file, one `Minitest::Test` subclass.** **Only tests are public**: every helper in a test
class is `private def`, except one a game block calls back through (`test = self`, then
`test.tileset(self)`) or a class method called as `TestThing.helper`. A helper another file needs
goes in a shared helper at `test/`.

The shared helpers stay at `test/` — `test_helper.rb`, `differential.rb`, `emulator_blend.rb`,
`mixed_sound.rb`, `conformance_fixture.rb`, `int32_cases.rb` (the calculations a runtime written
again in another language is held to), `runtime_sounds.rb` (the sound such a runtime is held
to, sample for sample against the native one's), `midpoint_circle.rb` (the answer key for a light's
rows), `many_rooms_game.rb` (a scene of many rooms with sprite pictures grouped by room),
`status_bar_games.rb` (small games with a status bar, for the verb's and its handle's tests),
`speakers.rb` (which speaker a cartridge's voice is heard from),
`many_tiles.rb` (backgrounds of many different tiles, for what a console does when they are too many to
hold at once), and the
helpers a test file shares with its `_on_the_advance.rb` twin (`fade_watch.rb`,
`tinted_handover.rb`) — and are loaded by bare name (`require "differential"`), never
`require_relative`.

## How a test file starts

```ruby
# frozen_string_literal: true

require "test_helper"

class TestThing < Minitest::Test
  def test_it_does_the_thing   # played on every lowering
    ...
  end
end
```

`test_helper` gives every test `Reference`, `SaveImage` (save memory for `Reference.new(save:)`
and the Verifier), `GBA`, `Builder`, `Color`, `ROM`, and `EmulatorSupport`
(`assert_emulator_loads_rom`, `assemble_rom`, `require_emulator!`). Do not re-declare them; a
constant declared in the file wins where it needs the name for something else. Narrower helpers
are opt-in: `include Differential`, `include CostArith`, `include VBlank::IR::Build`.

Commands and which run a change needs are in `runs.md`. One whole run holds the machine at a
time; in a worktree set `VBLANK_SUITE_LOCK=checkout`.

## Every test plays on every lowering

A test makes its player with `game_player`, never `Reference.new`, when the question is what the
game does: on the GBA run it is the interpreter, on the native run the game as C, on the
JavaScript run the game as JavaScript, on the Ruby run the game as Ruby, each checked against the
interpreter on every frame, and on the Game Boy Color run the Color cartridge, checked against the
interpreter after every pass. `Reference.new` by name is for a test of the interpreter itself. A
test that reaches for the Advance's cartridge in the emulator skips itself on the native,
JavaScript, Ruby and Color runs. A test one of them cannot play yet says `skip_on_native "why"`
(or `skip_on_js`, `skip_on_ruby`, `skip_on_gbc`). A test of one lowering's own output lives in a
folder that lowering owns and is played by its run alone (`TestSuites::LOWERING_FOLDERS`:
`ir/backends/gba/`, `diagnostics/` and `playthroughs/` for GBA, `ir/backends/native/`,
`ir/backends/js/`, `ir/backends/ruby/`, `ir/backends/gbc/`). See `lowerings.md`.

**What only the Advance can do is tested in `test/advance/`**, which the GBA, native, JavaScript
and Ruby runs load and the Color's never does: fading part of the screen, a recording in a song,
more colours in one 8×8 square of a painted screen than the Color holds, and every example whose
game is for the Advance alone. A new test of such a thing goes there, mirroring `test/`, in a file
of its own beside the shared one (`test_fade_held_to_area_on_the_advance.rb`), rather than skipping
on the Color. Don't bend a test to make it play on both. See `lowerings.md`.

## Ractors — fix what the runner reports

The GBA run plays the suite through minitest-ractor, a Ractor per test, and reports every test
that reached state the whole process shares. Those are order-dependent bugs, not noise; make the
code Ractor-friendly rather than silencing the report.

- read from a global or class variable while the test runs → read it once at load, into a constant
- a module's registry, or a lazy `@thing ||= …` → one per Ractor: `Ractor.current[:key] ||= …` or
  `Ractor.store_if_absent(:key) { … }`
- a fixture in a constant → nothing to do; `test_helper.rb` deep-freezes every constant a test
  class declares

A test that changes the whole process on purpose (registering a font or guardrail, stubbing a
library method, declaring a class, asserting the process's output) or starts a child process
(which hangs inside a Ractor) says `runs_on_the_main_ractor!` at the top, with a line saying why.
It is not somewhere to park a test nobody has looked at.

## Which frame's numbers the picture was drawn from

A pixel and a variable read at the same moment are not always the same frame, on every backend
and on real hardware:

- **What the program draws** (`pixel`, `fill_rect`, `draw_rect_at`, `blit`, bitmap `draw_text`)
  is in the picture for the pass that drew it. Picture and variable agree.
- **What the framework draws for you** (a sprite, a tiled text glyph, a background's scroll) is
  painted in the gap before the next frame, from the variables then. So on the Advance the
  picture shows the pass before: `v.var(:n)` is 5 while the sprite stands where 4 put it. The
  Color sends them from a copy as the gap ends, so each pass places them before its wait and the
  picture shows the pass just ended (`Console::Description#sprites_placed_before_wait`). A test
  that plays on both says how far behind with `framework_drawing_lag` (one, or none).
- **A picture painted from a list and said `changed now: true`** is the exception: it is
  copied where the game said so, during the pass, and its pixels are in that pass's picture
  (the sprite showing it still stands where the pass before put it).

On the Advance a position decided while a frame is being drawn cannot appear in that frame, so
this is not something to design away. In a test, run `framework_drawing_lag` frames further
before reading the picture, or read the variable that many frames earlier. `test/vblank/ir/test_frame_pairing.rb` pins both halves. It only
bites a test that pairs a picture with a variable.

## Building the program under test

- **IR directly**, when the lowering is under test: `include VBlank::IR::Build`, then
  `program(screen(:bitmap), clear_screen(:white), bitmap(:s, width:, height:, pixels:, transparent:), blit(:s, x, y), halt)`.
- **DSL**, when the surface is: `b = VBlank::Builder.new; b.instance_eval { … }; b.finalize_program; b.program`,
  or `VBlank.build("NAME", console: :gba) { … }` for a ROM (pass `out:`/`err:` a `StringIO` to assert
  warnings). A build always names its console. A Builder or a hand-built `program(...)` names none, and each
  run plays it as that run's console.
  Don't write a `code:`: made-up codes collide with real cartridges, which is a build error.

## Choosing test values

Make colours and positions diagnostic: a 4-pixel strip of red, green, blue and white catches a
wrong copy offset or count where a solid fill only proves something drew. For edge clipping,
assert the wrap target (e.g. `(239, y-1)`) is background, since the bug is a row wrapping onto
its neighbour.

## Guardrail tests

Assert the friendly error a misuse raises: its class and a key phrase, never the exact wording.

## Gotchas

- Don't name a helper `run`: it shadows `Minitest::Test#run`.
- `rake test:all` needs zig 0.17 on the path (`mise use zig@0.17.0`) and node 18+, or it stops at
  the start.
- Emulator tests fail loudly without the emulator rather than skipping; only the native and
  JavaScript runs skip them, saying so.

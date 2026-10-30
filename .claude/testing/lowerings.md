# The native, JavaScript, Ruby and Game Boy Color runs — the game as C, as JavaScript, as Ruby, as a Color cartridge

`rake test:all` plays the suite once per lowering (`test/support/suites.rb`): the GBA run (the
interpreter, the cartridge checked in the emulator), the native run (the game built as C by
`Backends::Native`, checked against the interpreter on every frame), the JavaScript run (the
game as JavaScript by `Backends::JS`, played by node, checked the same way), the Ruby run (the game
as Ruby by `Backends::Ruby`, played by a Ruby of its own, checked the same way), and last the Game Boy
Color run (the game built as a Color cartridge by `Backends::GBC`, played in the emulator and
checked against the interpreter after every pass). The native, JavaScript and Ruby runs are each
played once for every console (`rake test:lowering:native:gbc` is one), since their builds are told
the console when they are made; each loads `test/all/`, its console's folder and its lowering's.
`CONSOLE=gbc` keeps only the runs that play games as that console. A test that fails on any of them fails the run.
It needs zig 0.17 and node 18 or later besides the emulator.

**The Game Boy Color run plays every test it can make work, and never sees the rest.** Its player
(`Testing::CartridgeCheckedPlayer.for(:gbc)`, made from the Color's kit over `GBC::CheckedRun`) plays each test's program as a Color program and compares
variables, lists, the picture, sprites, the sound log and save memory with the interpreter's —
playing the interpreter as a Color, so a fade or a turned background the Color shows differently is
checked as the Color shows it. The sound log is read off the cartridge that ships, with nothing
added to it: the emulator records the processor at each of the runtime's sound routines, and what
each was handed says what it played (`GBC::SoundLog`). What the Color's hardware cannot do — fading
part of the screen, a recording in a song, a save on flash, more colours in one 8×8 square of a
painted screen, more tiles or memory than it holds — is tested in `test/console/gba/`
(`TestSuites::ADVANCE_DIR`), which every run of an Advance game loads (GBA, native, JavaScript, Ruby) and
the Color's never does; so is every example whose game says it is for the Advance alone. A new test
of such a thing goes there, mirroring test/ (`test/console/gba/vblank/builder/`), in a file of its own
beside the shared one (`test_fade_held_to_area_on_the_advance.rb`), rather than skipping on the
Color. Don't bend a test to make it play on both: one about the Advance's picture is the
Advance's. What the Color could do and its build does not make yet (`GBC::Lowering::NOT_LOWERED_YET`)
fails on the Color run until it is made — that failure is the work still owed. The one skip is a
call its run cannot answer (`GBC::HeadlessRun::CannotAnswer`), counted by reason at the end;
`skip_on_gbc` is there for a test the Color's build cannot play for a reason no folder says
(`skip_on_console :gbc` when it is the Color's hardware that cannot, so the runtimes' runs built
as the Color skip it too), and
`test/lowering/gbc/vblank/ir/backends/gbc/` is its own folder. A game built for both consoles
(`consoles: %i[gba gbc]`) is played there as a Color game, as `examples/pacman.rb` and
`examples/breakout.rb` are; `examples/pong_gbc.rb` is a game for the Color alone, a copy of
`examples/pong.rb` changed for it, since the Advance's title zooms on a screen the Color cannot turn.
**The Super Nintendo run is built the way the Color's is.** Its player (`CartridgeCheckedPlayer.for(:snes)`, over
`SNES::CheckedRun`) plays each test's program as a Super Nintendo program in bsnes
(ruby-snes-emulator, whose core `rake compile_snes_core` builds) and compares variables, lists,
the picture and sprites with the interpreter's after every pass. A test whose program reaches a
part its build does not make yet (`SNES::Lowering::NOT_LOWERED_YET`) skips, saying which part, and
the run counts those skips by reason; `skip_on_snes` is there for a test it cannot play for a
reason no folder says. `test/lowering/snes/vblank/ir/backends/snes/` is its own folder, and its `examples/`
mirrors `examples/`: a test there plays one example built for the Super Nintendo too
(`consoles: %i[gba snes]`).
`test/console/gba/` is loaded by every run that plays games as the Advance: the GBA lowering's, and
the native, JavaScript and Ruby runs playing as the Advance. A console's folder is named in
`TestSuites::CONSOLE_FOLDERS` and a lowering's in `TestSuites::LOWERING_FOLDERS`
(`Testing::Lowering.files_for`).

**The JavaScript run is the native run's twin.** Its game is the native lowering's statements
printed as JavaScript, its windowless program prints what the native one prints, and its player
(`JSCheckedPlayer`, `JS::CheckedRun`) is the native checked run with that program swapped in. So
all of this file holds for it too, with `skip_on_js` for its own skip and
`test/lowering/js/vblank/ir/backends/js/` for its own folder. The sound a speaker would make is compared
with the cartridge's on the native run alone (`.claude/testing/native-sound.md`); the JavaScript
runtime's voices are the native one's, function for function.

**The Ruby run is played and read the same way.** Its windowless program, a Ruby script run by a
Ruby of its own, prints the same lines, and its player (`RubyCheckedPlayer`, `Ruby::CheckedRun`)
compares the same things. `skip_on_ruby` is its own skip and `test/lowering/ruby/vblank/ir/backends/ruby/` its
own folder. While its runtime is still being written, a game that needs a part it lacks is found
when the game is built (`Ruby::Lowering#runtime_gaps`) and the test skips naming the part; the
run's count of skips by reason is the list of what is left.

## What `game_player` is on each run

On the GBA run it IS `Reference.new`. On the native run it is a `CheckedPlayer`: the game built as
C, driven through the same calls (`hold`, `input_each_frame`, `each_vblank`, `run`, `[]`, `vars`,
`screen.pixel`, `screen.to_a`, `screen.stored_pixel`, `screen.camera_x`/`camera_y`, `sprites`,
`list`, `pool`, `game_state`, `buffered`, `audio`, growing with each native slice), then the same
buttons replayed on the interpreter, failing at the first frame where any variable, list or pool
field, pixel, the sound log or the sprites drawn differ. Every test's own checks are backed by a
whole-picture comparison on every frame.

What it cannot answer yet raises `HeadlessRun::CannotAnswer` naming the call: the native lowering
has a gap to fill, and the test skips saying so (`Testing::MissingFeature`), as a test does that
says `skip_on_native "why"` for a feature the lowering lacks. A question only the interpreter has
(`frames_each_pass`, a power cut after N steps) raises `RunComparison::AsksTheInterpreter` and
fails: that test belongs in `test/interpreter/`. A test that reaches for the Advance's cartridge
(`require_emulator!`, `assert_emulator_loads_rom`) fails too: it belongs in `test/lowering/gba/`.
The run ends with its skips counted by reason, and fails if any is not a missing feature.

- **Saves.** `game_player(save: image)` hands the C the image's bytes as a .sav file, puts what
  the run left back into the image (so one image handed to two runs is a power cycle, as for the
  interpreter), replays on the interpreter from a copy taken first, and fails if the two end with
  different bytes. `cut_power_after` cuts both at the same step.
- **`each_vblank`** with a block watches the C at each frame boundary as the run goes, and an
  input script can read the picture as well as the variables.
- **A step budget** (`run(program, max_steps: 400)`) needs nothing changed: it stops on a frame
  boundary, so the interpreter is asked how many frames fit and the C plays that many.
- **Sound.** The log is the interpreter's words for what was played. The C keeps it, and plays
  the sound, for songs (square, wave, noise and recordings; named or from a list; played once;
  the music volume), effects over the song, beeps, `wave`, `stop_wave`, `noise`, and recordings.
  The mixer's output is compared slice for slice (`mixed_sound`, `active_samples`,
  `sound_owners`, `peak_voices`, `volume_of`, `level_of`, `sound_drops` answer). A test may clear
  `audio` as it watches; the run compares every entry the C logged regardless.
- **`assert_backends_agree` and `backend_pictures` do not skip.** They play the program as C
  with the same buttons and compare with the interpreter on every frame; `backend_pictures`
  hands back the C's picture in place of the console's. How the console is lined up against the
  interpreter is the GBA lowering's alone (`ir/backends/gba/test_console_line_up.rb`).

## Reading every frame is one run

A helper that plays the game again for each frame it looks at costs the square of the frames,
and the native run starts the C afresh each time. Read frames as they settle with `each_vblank`
(the `watch` helper in `test_screen_fade.rb`, which also shows the one-frame offset).

## Examples on the native run

`ruby tools/native_examples.rb` lists the examples the native lowering can write as C today and
why each other is refused. `test_native_examples.rb` fails when one that builds has no recorded
run (`native/examples/test_<example>_picture.rb`), or when a file in `test/all/examples/` whose
examples all build still plays them by `Reference.new`. A file whose tests are all of the
cartridge has nothing for the C to play.

A whole example gets files under `test/lowering/native/vblank/ir/backends/native/examples/`:
`test_<game>_picture.rb` plays a recorded run of buttons and compares every variable, pixel and
the sound log with the interpreter's on every frame, and `test_<game>_sounds.rb` compares the
speaker with the cartridge's. `test_pong_*.rb` and `test_pacman_*.rb` are the worked examples. A
small made-up program for one feature goes in `test_native_picture.rb` or `test_native_tones.rb`
and never requires an example.

## It is the library's, so a game does the same

This suite takes it from the library exactly as a game does. `require "vblank/testing"`
(`lib/vblank/testing.rb`) is minitest, the library, the lowering the run is for
(`VBlank::Testing.lowering`, read once from `VBLANK_LOWERING`), and a module giving
`game_player`, `skip_on_native` and `CheckedPlayer`. `CheckedPlayer` is
`VBlank::IR::Backends::Native::CheckedRun` with a disagreement reported as a failed test; the
comparisons are `Native::Differences`. The rake tasks are the library's
(`VBlank::Testing::RakeTasks`): this Rakefile makes `rake test:all` and the `test:lowering:` tasks
with it, handing over the test files, the lowering folders and the consoles (`%i[gba gbc]`; a
game's Rakefile that names none gets no Color run), and adds only the machine lock, the emulator
build and coverage. Each `test:lowering:`
task is a `VBlank::Testing::TestTask`, which holds how a native run starts (no Ractors, several
processes, zig asked for first). The README's "Testing a game on every lowering" is the game's
side; `test/all/vblank/testing/test_game_suite.rb` runs the rake of a small game suite
(`test/fixtures/game_suite/`) that has the library as a gem and nothing from this folder.

A native player needs zig and starts the game as a separate program, so it cannot run inside a
Ractor. How the native run's processes work is in `.claude/testing/runs.md`.

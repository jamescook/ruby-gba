---
paths:
  - "lib/ruby_gba/ir/backends/**"
  - "test/ruby_gba/ir/backends/**"
---

# Adding a backend

How to add the next lowering (a terminal one is the likely one): what every backend has to do,
where it plugs in, what it is checked against, and the traps. Written from what the native
lowering (`Backends::Native`, the game as C) actually took, and checked against what the
JavaScript one (`Backends::JS`) took after it. C-only decisions are in the comment atop
`Backends::Native`, JavaScript-only ones atop `Backends::JS`, not here.

## What a backend is

A backend takes an IR tree (`IR::Node`, built by the DSL and checked by `IR::Verifier` and the
guardrails) and either runs it or writes it out as something else that runs. It knows nothing the
IR does not say: the IR is target-neutral, and a backend never reaches back into the DSL or the
builder.

There are five today:

- `Backends::Reference` runs the tree in Ruby. **It is the answer key**: what a program means is
  what Reference does with it. It is named for that role, not for its language.
- `Backends::GBA` lowers the tree to ARM and a cartridge.
- `Backends::Native` writes the tree out as C, built by zig into a desktop program.
- `Backends::JS` writes the tree out as JavaScript, for a web page, and for node in the tests.
- `Backends::GBC` lowers the tree to SM83 code and a Game Boy Color cartridge (MBC5).

## A second console

The Game Boy Color is the first backend for a console other than the Advance, and it showed what
a console of its own needs beyond a lowering:

- **A description** (`Console::Description`, `Console.described(:gbc)`): its screen size, what it
  can blend, how long a frame is, the rates its mix of recordings can run at
  (`Console::SampleClock`), the most one pool can take, and the rest a game or the interpreter
  asks of a console. A game says which consoles it is for (`consoles: %i[gba gbc]`) and reads
  `screen_width` and `screen_height` rather than writing 240 and 160. The builder and the
  interpreter read these from the program's console and never from one console's hardware
  file (`Console::Hardware` is the GBA lowering's), so the answer key and the cartridge agree
  about what the console cannot do (a fade the Color does not blend is walked colour by colour,
  `IR::Fading`). What every backend must count alike, a fade's steps and a pixelate's biggest
  block (`Backends::FadeSteps`, `Backends::Blocks`), is written there once, and a console's
  lowering is checked against it.
- **An answer for every verb** (`Console::ColorAnswers`; every console has one, the Advance's
  `Console::AdvanceAnswers` included, and `Console::Answers` says what an answer is): it works, or
  it is refused in plain words naming the hardware the console lacks. Nothing is shown differently.
  The guardrail check (`Checks::ConsoleAnswers`) gives those answers at build time for whichever
  console the build is for, working out which part of a verb a line asks for from the console's
  description (its buttons, whether it blends, turns a background or turns a sprite). Each
  console's page under `.claude/dsl/` is generated from its table (`tools/console_answers.rb`),
  so the docs cannot drift from it. The checks that count something the console has — layers,
  sprites, sprites on a row — read the number from its description.
- **Its own cartridge, emulator reading and profiler** (`Cartridge::GBCROM`,
  `Diagnostics::GBCProfiler`): the Advance's never learn about it.
- **A kit naming all of it** (`Console::Kit`, `Console.for(:gbc)`, in `console/kit.rb`): its
  description, its answers, the build that makes its cartridge (`Cartridge::ColorBuild`, handed a
  `Cartridge::BuildRequest`), the cartridge kind, its reader, whether its builds are measured, and
  whether the desktop and web runtimes can draw it (`drawn_by_runtimes?`; they draw one screen
  size today, the Advance's, so `Console.drawn_by_runtimes` picks the console those builds are made as).
  The build, the reader chooser, the cartridge-file reader and the command line ask the kit, so a
  console is added by describing it and giving it a kit. Nothing outside a console's own code
  compares console names (`test/ruby_gba/console/test_kit.rb` fails the build if something does).
- **No console by default.** A game names its consoles, a build (`RubyGBA.build(..., console:)`)
  and a Rakefile (`t.consoles`) name theirs, and a name is held as its Symbol however it was
  written (`Console.named`). Only an unbound program, a tree built for a test (a Builder told
  none, a hand-built `program(...)`), names none, and each run plays it as that run's console.

`GBC::Lowering` is a peer of the GBA lowering, not of the native one: it walks the IR and emits
SM83 machine code itself (its picture and sound in `GBC::Lowering::Picture` and
`GBC::Lowering::Sound`), through the Ruby assembler (`GBC::SM83`), calling a runtime written in
SM83 the same way. It shares with the other lowerings only what the IR says (`IR::Reach`,
`IR::Frames`, `IR::SceneHandover`, `IR::SaveLayout`), never another lowering's code. The comment
atop `Backends::GBC` says the rest.

## Start from the native lowering's statements

`Native::Lowering` does not write C text: it builds a small tree of statements (`Native::C`) —
globals, routines, constant tables, and calls into a runtime — and only `Native::Printer` turns
that into C. There is no operator anywhere in it (every number goes through a runtime function
that does what `IR::Int32` does), so nothing in it is C's alone. The JavaScript lowering is that
same tree printed by `JS::Printer`, and a runtime (`js/runtime/*.js`) that is the native one's C
written again, function for function: `JS::Lowering < Native::Lowering`. Everything that decides
what a program says — which art is worked out in Ruby, which kinds are not lowered yet — is then
said once, and the two lowerings can only differ in how a runtime does a thing, which the checked
run finds.

A new lowering for a machine that can run a runtime of that shape should start there too, and
only write a lowering of its own when the tree cannot say what its machine needs.

A new backend is named for the platform it targets (`JS`, not `Canvas` or `V8`), lives in
`lib/ruby_gba/ir/backends/<name>.rb` beside a folder of the same name, and is required from
`lib/ruby_gba/ir/backends.rb`.

## Checked by running, never by output

A backend is right when a game played on it does what the same game does on Reference: the same
variables, lists, pool fields, picture, sprites, sound log and mixed sound, on every frame.
Native is held to that by `Native::CheckedRun`: it plays the game as C, plays the same buttons on
Reference, and fails at the first frame the two differ. Nothing compares generated code against
code somebody wrote down; a test of a backend's own output (the ARM it emits, the C it writes)
is the exception, and lives in that backend's own test folder.

What a new lowering needs for this, following Native:

- a **headless run** that takes the interpreter's calls (`hold`, `input_each_frame`,
  `each_vblank`, `run(program, frames:)`, `[]`, `vars`, `screen.pixel`, `sprites`, `list`,
  `pool`, `audio` and the rest a test reaches for), so a test written against Reference plays
  the game on it unchanged (`Native::HeadlessRun`);
- a **checked run** that plays it and then Reference on the same buttons and compares every
  frame (`Native::CheckedRun`, with the comparisons in `Native::Differences`);
- what it cannot answer yet raises by name (`HeadlessRun::CannotAnswer`), never guesses.

## The contracts every backend honours

- **`IR::Int32` is the arithmetic.** Signed 32-bit two's complement, wrapping. Every value
  operation a backend does maps onto one of its functions, and nothing else does arithmetic on a
  game's numbers. Native writes them as C functions in `runtime/rg_int32.h` and never uses a C
  operator on a game's number; a JavaScript backend, whose numbers are 64-bit floats, needs the
  same discipline (`| 0`, `Math.imul`, explicit wrapping), or it agrees with the others until the
  first number wraps.
- **Console-only kinds are refused up front.** `IR::Portability` tags each kind `:portable` or
  `:hardware_only` (`raw` and `read_scanline` today). A backend that cannot run one refuses a
  program that can REACH one, before writing anything, with a plain message
  (`Native::Lowering#refuse_unlowered_kinds!`). A hardware-only step in a routine nothing calls
  is not refused: it never runs, and Reference does the same.
- **Dispatch is one method per kind.** Reference keeps a `STATEMENTS` table and a `VALUES` table
  (kind to method name); Native keeps the same two, so the two read side by side and a missing
  kind is one line to find. A new backend keeps them too. A kind it cannot do yet goes on a list
  of its own (Native has `NOT_LOWERED_YET`, empty now), held by a coverage test
  (`test/ruby_gba/ir/backends/native/test_native_kind_coverage.rb`) so every kind is either done
  or listed. `test/ruby_gba/ir/test_kind_coverage.rb` holds Reference and the GBA lowering to
  every kind the same way.
- **The conformance fixture.** `test/conformance_fixture.rb` is one program that touches every
  kind and every operator. `test/ruby_gba/ir/test_cross_backend_conformance.rb` plays it on the
  lowering under test (`test_the_lowering_under_test_plays_the_whole_fixture`); a new lowering
  joins that test rather than getting a copy of it.
- **`Node#source`** is the DSL line that made a node (`"file.rb:12"`), where the builder knew it.
  Keep it in what you write out, so an error in generated code points at the game.

## Semantics a backend gets wrong without noticing

Each of these is what Reference does; check the line before relying on it.

- **`and` and `or` evaluate both sides.** No short-circuit, unlike `&&` in C and JavaScript.
  Reference evaluates both operands before `eval_binop` combines them; Native calls
  `rg_both`/`rg_either` on two evaluated values.
- **`case` reads its variable once**, before the first clause, and runs every clause whose value
  matches (`Reference#exec_case`). A scene that sets the variable to the next scene must not
  start that scene in the same pass.
- **`repeat` evaluates its count once** and checks `stop_when` BEFORE the body, so a loop already
  finished on its first pass runs nothing (`Reference#exec_repeat`).
- **Dividing by zero gives 1, or -1 for a negative numerator**, and `%` by zero gives the number
  back (`Int32.div`, `Int32.quotient_by_zero`). The game does not stop. `/` truncates toward zero
  and `%` takes Ruby's meaning (the sign of the divisor), so the two do not decompose on negatives.
- **Shifts by 32 or more empty the number**, and a negative count does too, rather than turning
  round (`Int32.shift_left`, `Int32.shift_right`).
- **A list index out of range stops the game with an error** on Reference
  (`IR::ProgramError`); Native ends with `RG_GAME_WENT_WRONG` and the same words. **A table index
  never does**: a power-of-two length wraps it, any other clamps it to the ends.
- **A narrow list slot keeps the low bits and reads back sign-extended**: 200 in a `:byte` slot
  reads -56 (`Reference::ListValue#wrap_to_width`).
- **A frame can end anywhere.** `wait_vblank` may sit deep inside a routine, in a loop, in a
  scene called from a scene: the runtime has to take a frame from the middle of a call and come
  back to it (Reference's `advance_frame` runs synchronously inside `exec_wait_vblank`; Native's
  `rg_wait_vblank` hands the frame to its driver and returns). A browser cannot block, so the
  JavaScript lowering writes every routine that can reach a wait as a generator, the wait as
  `yield` and a call to one as `yield*`, and its driver plays the game a frame at a time
  (`JS::Printer` says how; a routine that never waits stays a plain function).
- **`halt` never returns.**

## Joining the test runs

`rake test` plays the suite once for each lowering; a new one is a fifth run.
`RubyGBA::Testing` (lib/ruby_gba/testing/) is where that is decided, and it is the same code a
game's own suite uses:

- `Testing::Lowering::NAMES` lists the lowerings and `RUBY_GBA_LOWERING` picks one.
- `RubyGBA::Testing#game_player` hands a test the player for the run: Reference on the GBA run,
  the checked player on the native, JavaScript and Game Boy Color ones (`Testing.player_class`). A new lowering
  adds its checked player there, and to `Lowering::CHECKED`.
- `Testing::TestTask` says how a run is started (the native and JavaScript ones in several
  processes, never in Ractors, since they start programs); `Testing::RakeTasks` makes `rake test` and a
  `test:lowering:<name>` task for each.
- `TestSuites::LOWERING_FOLDERS` (test/support/suites.rb) names the folders only one lowering's
  run loads: put the new backend's own tests in `test/ruby_gba/ir/backends/<name>/`.
- **What a checked run does differently** is asked as `Testing.checked?`, which a new lowering
  joins through `Lowering::CHECKED`: `require_emulator!` in `test/test_helper.rb` (a test of the
  cartridge skips on every run but the GBA one), `Testing::Pictures` and `test/mixed_sound.rb`
  (on a checked run they compare the lowered game instead of the cartridge), and the process
  runner `Testing::TestTask` starts such a run with. A lowering adds its own skip
  (`skip_on_native`, `skip_on_js`, `skip_on_gbc`), and its test folder to
  `TestSuites::LOWERING_FOLDERS`.
- **Reuse the native checked run.** `Native::HeadlessRun` reads a program that prints
  runtime/rg_headless.c's lines, and `Native::CheckedRun` compares it with the interpreter; a
  windowless program of the new lowering that prints the same lines is read and checked by
  them, through a subclass that says how its program is built (`JS::HeadlessRun`,
  `JS::CheckedRun`).

## What done means

A backend is done when every test plays on it and `rake test` passes: there is no lowering that
trails. On the way there, a test it cannot play yet skips itself with a reason
(`skip_on_native` is native's version), and the run counts its skips by reason at the end so
they cannot pile up. A hardware feature is not done until it works on every backend; when one is
on the radar, record each backend's slice as its own piece of work.

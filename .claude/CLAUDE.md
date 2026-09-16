# ruby-gba

Ruby DSL for building Game Boy Advance ROM files. Pure Ruby, no C extensions — the
framework itself never leaves Ruby. (The emulator used to verify ROMs, ruby-gba-emulator, is
a separate gem with its own C extension; see "Emulator & integration tests" below.)

## Design philosophy — the DX north star

This is a **teaching tool first**. Assume the person writing a ROM knows **Ruby**, and does
**not** know the GBA's hardware or graphics programming — not VRAM, DMA, DISPCNT, palettes,
"indexed color", display modes, VBlank, sprites/OAM, or ARM. Design every user-facing API so
they never *have* to. When adding a feature, this ranks above cleverness or byte-efficiency.

- **Hide the hardware.** The common path uses plain intent and color *names*, never registers
  or jargon. Manage the machinery — palettes, page flips, VRAM layout, VBlank timing, DMA —
  *for* the user. If a feature is technically "indexed color", they should still just write
  color names (the framework builds the palette silently).
- **Footguns become teaching errors.** The worst part of learning GBA is that every mistake is
  the same silent black screen. Turn known footguns into friendly, plain-language errors and
  warnings that say what happened and how to fix it — and auto-fix where safe. Never a hardware
  lecture. This is what `IR::Guardrails` (build-time) and `ROMValidator` (finished-ROM) are for.
- **Safe by default, power on request.** Sensible defaults (edge clipping, safe writes, sane
  modes) so nothing corrupts memory or silently fails; keep the low-level escape hatches (raw
  asm-tier ops, explicit modes, raw data arrays) available for people who want them.
- **Names read like game code**, not assembly — `flip`, `approach`, `blit :ship, x, y`.

## Shell commands — one operation per call

Run **one logical command per Bash call.** Do not chain distinct operations with `&&`, `;`,
or newlines in a single invocation, and do not bundle a file-writing heredoc
(`cat > f <<EOF …`) with the command that consumes it.

Why this is non-negotiable here: the operator reads each command before allowing it, and the
permission allow/denylist matches on recognizable prefixes (`git commit`, `rake test:parallel`).
A blob like `cat > msg <<EOF … EOF; git add .; git commit -F msg; git show` is unreadable,
can't be allowlisted, and can't be denied granularly.

- `git add`, then `git commit`, then `git show` are **three separate Bash calls**, not one.
  Need several commands at once? Issue several Bash calls (they can run in parallel) — each
  stays individually matchable.
- Write files — commit messages, scripts, long bodies of text — with the **Write/Edit tools**,
  never `cat >`/heredocs. Then a single command reads the file (`git commit -F <file>`).
- No `python3 -c '…'` / `ruby -e '…'` logic one-liners. Put logic in a file so it's
  inspectable and re-runnable.
- Prefer one clear command over a clever pipeline, even for read-only inspection.


## Emulator & integration tests

Integration tests run ROMs in an emulator via **ruby-gba-emulator** — a lean, headless libmgba
probe. It is a **gem of its own**, living in this repository under `ruby-gba-emulator/`, and it
is reached through the one seam, `RubyGBA::Diagnostics::Emulator` (`lib/ruby_gba/diagnostics/emulator.rb`), so nothing
else names the backend directly.

**Why a separate gem:** building a cartridge is pure Ruby and running one is not. It is
deliberately NOT a dependency of ruby-gba's gemspec, so somebody who only builds cartridges
needs no C compiler. A game that wants to verify or profile adds it to its own Gemfile:

```ruby
git "https://github.com/jamescook/ruby-gba.git", glob: "{,ruby-gba-emulator/}*.gemspec" do
  gem "ruby-gba"
  gem "ruby-gba-emulator"
end
```

**One block for both gems, not two `gem ... github:` lines.** The two-line form looks
equivalent and is not: bundler counts `glob:` as part of a git source's identity, so two lines
with different globs are TWO sources — while the directory it clones into is named from the URL
alone. Two sources into one directory races on a cold cache and the clone dies outright
(`cannot copy ... info/exclude: File exists`, or `shallow file has changed since we read it`).
One block is one source, one clone, and the two gems can never land on different commits.

Taking it through bundler is what keeps the built extension tied to the Ruby that built it —
bundler installs extensions per Ruby ABI, so changing Ruby rebuilds rather than leaving a
library that will not load.

**In THIS repository** it is a `path:` entry in the Gemfile, so `require "ruby_gba_emulator"`
resolves and the seam takes the same route a consumer takes rather than a fallback nobody else
has. Bundler does NOT build its extension though — it builds them for gem and git sources, not
for a path one — so `rake compile_emulator` does that (a prerequisite of every test task;
`rake test:emulator` builds and runs its own suite). That build is keyed on source files being
newer, which cannot see a Ruby version change — after switching Ruby, run `rake clean` in
`ruby-gba-emulator/`. The load error tells you which of the two you are looking at.

It is **required, not optional**: if it can't build or load, the emulator-backed tests **fail
loudly** rather than skipping — `require_emulator!` (in `EmulatorSupport`) raises. Building it
needs a C compiler and a system libmgba (`brew install mgba` / `apt install libmgba-dev`).

## Running Tests

**`rake test:parallel` is how the suite is run.** It runs across processes and is several times
faster; bare `rake test` runs everything in one process and is slow enough to be the wrong
command every time. Reach for `rake test` ONLY to run one file or one test:

```bash
rake test:parallel                                              # the suite (JOBS=8 to pick a count)
rake test TEST=test/language/test_thing.rb                      # one file
rake test TEST=test/language/test_thing.rb TESTOPTS="--name=/pattern/"  # one test
```

Test files live in five directories, by what the test is about: `test/language/`
(the program's own logic), `test/console/` (what the machine shows and plays —
`drawing/`, `sprites/`, `world/`, `audio/`), `test/guardrails/` (one known mistake
each), `test/examples/` (a shipped program run end to end) and `test/toolchain/`
(the framework's own machinery — `ir/`, `cost/`, `tools/`). They are NOT split by
which backend a test asserts against; most files assert against both. The shared
helpers stay at `test/` and are loaded by bare name. See `.claude/rules/testing.md`
for the rule that decides a new file's home.

The framework's largest consumer, a Wolfenstein 3D port, lives in its own repository at
`~/open_source/ruby-wolf3d` and depends on this one as a gem. It has a suite of its own which
this one does not run and must not learn about: a library that names the games built on it is
coupled to them. Its whole purpose is to find gaps here, and a gap it finds is tracked against
this framework rather than worked around there. To work on both at once, point its bundler at
this checkout (`bundle config set --local local.ruby-gba ../ruby-gba` from there).

## Testing strategy — assert behavior, at the right altitude

Test each layer the way a player experiences it, not by restating the code.

- **DSL level — assert what the program *does*, never the IR it builds.** Build a
  small program through the DSL, run it, and check the observable result: the
  pixels on screen, the sound produced. A tree-equality assertion (rebuilding the
  expected `IR::Node` with the same `Build.*` constructors the DSL uses) is a
  change-detector — it restates the mapping, stays green even when a shared wrong
  mental model is baked into both sides, and breaks on any harmless reshape.
  Don't write those.
  - **Fast path: the reference interpreter (`IR::Backends::Reference`) is a headless
    oracle.** Run a program and read its fake screen —
    `i = Reference.new.run(program); i.screen.pixel(x, y)` — or its variables (`i[:name]`).
    In-process, deterministic, no emulator. Assert a green pixel at (x, y), a
    marker whose position reveals a computed value, an edge that fires once, frame
    by frame. `test/language/test_dsl_expression.rb` is the worked example.
  - **Hardware path: the emulator** runs the real ROM and reads real pixels/audio
    (`assert_emulator_loads_rom` → `Verifier`). Keep a couple per feature to confirm
    the lowering; they fail loudly when the emulator is absent.
  - Supply input through the interpreter's `hold(:btn)` / `input_each_frame { }`
    and the emulator's `keys:`, not by poking internal state.
  - **A pixel and a variable read at the same moment are not always the same frame.**
    What the program draws itself is in step with its variables; what the framework
    redraws for you every frame — a sprite, a HUD glyph, a background's scroll — shows
    the value from the frame before, on both backends and on real hardware. See
    "Which frame's numbers the picture was drawn from" in `.claude/rules/testing.md`.
  - Guardrail tests are behavioral too: assert the *friendly error* a misuse
    raises (a dropped `.then`, an unknown button) — the class and a key phrase,
    not the wording verbatim.

- **IR backend level — opcodes and lowering are fair game.** Here the generated
  code *is* the contract, so `test/toolchain/ir/test_ir_backend_gba.rb` may assert
  the two-pass jump math, register conventions, or instruction shapes, and
  `test/toolchain/ir/test_ir_backend_reference.rb` asserts interpreter state. These build hand-made
  `IR::Build` trees (not the DSL) because they test the backend, not the surface.

- **Cross-backend:** a feature isn't done until it's tested on every backend it
  touches — the GBA lowering *and* the Ruby interpreter (see the cross-backend
  rule under Codegen IR).

## Architecture

### Where a lib file goes

`lib/ruby_gba/` is five modules, each a directory, by what a file IS — never by what it
happens to touch:

| directory | module | a file goes here when… |
|---|---|---|
| `dsl/` | `RubyGBA::DSL` | a game names it directly (a `Value`, a `Sprite`, a `List`), or it is a kind of thing one of those holds (`Whole`, `Fraction`, `NameSet`) |
| `audio/` | `RubyGBA::Audio` | it is the sound and music model behind the verbs (`Score`, `Envelope`, `Music`) |
| `graphics/` | `RubyGBA::Graphics` | it is what a picture is made of — colours, letters, images |
| `cartridge/` | `RubyGBA::Cartridge` | it turns a checked program into cartridge bytes (`ROM`, `ASM`, `Constants`) |
| `diagnostics/` | `RubyGBA::Diagnostics` | it reads a built or running cartridge back, or says something to the author about their build (`Verifier`, `Profiler`, `BuildReport`, `PlainWords`) |

The directory and the module always match: a file in `audio/` defines its classes inside
`module RubyGBA; module Audio`. A file whose home is not obvious goes where its CALLERS would
look for it, and a new directory per feature is the flat list again one level down, so there
isn't one.

What stays at the top: `builder.rb`, `ir.rb` and `effects.rb`, the front doors of the three
directories that were already modules of their own (`builder/`, `ir/`, `effects/`) — anything
in those stays there; `version.rb`; and `cli.rb` and `pager.rb`, the command-line program,
which `bin/ruby-gba` requires and the library never does. `RubyGBA.game` and the two error
classes stay on `RubyGBA` itself.

Inside a module, a sibling is named bare (`Value` from `dsl/pool.rb`) and anything else by its
module (`Graphics::Color` from `dsl/sprite.rb`). Where a nearer scope has a constant of the
same name — the GBA backend has an `Audio` class of its own — write the whole path,
`RubyGBA::Audio::Score`, because `Audio::Score` there means the wrong thing.

### Core Files

- `lib/ruby_gba/builder.rb` — The DSL entry point (`Builder`). Thin now: it `require`s and
  `include`s one concern module per area from `lib/ruby_gba/builder/` (19 files), each
  owning a slice of the flat verb surface — `randomness`, `sound`, `music`, `text`,
  `images`, `sprites`, `sprite_import`, `input`, `drawing`, `variables`, `control_flow`,
  `scenes`, `collision`, `tiled`, `composition`, `timers`, `sampled_audio`, `layers`. Every
  verb builds a node in an IR tree and returns; nothing here emits ARM (see "Codegen IR").
- `lib/ruby_gba/cartridge/asm.rb` — ARM7TDMI instruction encoding (MOV, LDR, STR, branch, etc), used
  by the GBA lowering backend and by the `entry` escape hatch's raw-instruction context.
- `lib/ruby_gba/ir/` — Intermediate representation: a plain-Ruby op-tree the DSL builds instead of emitting target code directly. `node.rb` (`IR::Node`), `build.rb` (readable constructors). See "Codegen IR" below.
- `lib/ruby_gba/cartridge/rom.rb` — ROM buffer management, header, finalization
- `lib/ruby_gba/cartridge/game_code.rb` — the four characters an emulator tells one cartridge from
  another by. A game need not write one (`GameCode.for(title)` works a free one out), and a
  code a real cartridge already carries is refused — the list it checks against is
  `lib/ruby_gba/data/known_game_codes.txt`, regenerated by `tools/make_known_game_codes.rb`
- `lib/ruby_gba/cartridge/constants.rb` — GBA hardware register addresses and flags
- `lib/ruby_gba/audio/music.rb` — Music DSL (`SongContext`, note frequencies, duration math). Channel 1 for music, channel 2 for SFX
- `lib/ruby_gba/graphics/color.rb` — 15-bit BGR555 color handling, named presets
- `lib/ruby_gba/graphics/font.rb` — Bitmap font model (glyphs + metrics); built-in fonts registered in `fonts.rb`
- `lib/ruby_gba/cartridge/rom_validator.rb` — ROM validation (header, checksum, structural checks) — `ROMValidator`
- `lib/ruby_gba/diagnostics/inspector.rb` — ROM disassembly and header reporting
- `lib/ruby_gba/diagnostics/verifier.rb` — Pixel-level verification via libmgba (through the `RubyGBA::Diagnostics::Emulator` seam → ruby-gba-emulator)
- `lib/ruby_gba/diagnostics/emulator.rb` — The one seam to the emulator backend; swap emulators here
- `lib/ruby_gba/cartridge/test_patterns.rb` — Built-in test ROMs (solid fill, color bars, etc)

### How It Works

The DSL builds an intermediate representation (IR) tree as the user's block runs — no ARM is
emitted yet. `RubyGBA.build` creates a `Builder`, evaluates the block, then: checks the tree's
internal consistency (`IR::Verifier`), runs it through `IR::Guardrails::Validator` (friendly,
plain-language warnings/errors for known footguns — nothing is auto-fixed), lowers it to ARM
machine code (`IR::Backends::GBA`), and hands that to `ROM.assemble`, which finalizes the header
(checksum, entry branch) and returns a `ROM` object.

### Codegen IR

The DSL builds an **intermediate representation** first, rather than emitting target code
directly: an in-memory op-tree (`lib/ruby_gba/ir/`, `IR::Node`) that a validation pass **checks**
(catching black-screen footguns before any code exists) and a lowering pass then turns into
machine code. Building the program as inspectable data — not bytes emitted on the fly — is what
makes validation, forward references (resolved by name in a second pass, replacing hand-rolled
branch-offset math), and a register allocator possible. (A register allocator is the one piece
this design allows for but doesn't have yet — see the register-convention comment atop
`IR::Backends::GBA`.)

Keep the IR **target-agnostic**: `IR::Node` describes *what the program does*, not how one machine runs it. ARM/GBA is the current lowering backend, but nothing in the node model assumes it — another backend (e.g. JavaScript) could lower the same tree. Put target-specific detail in the lowering pass, never in the IR core — and that includes code comments: don't frame the IR around GBA/ARM.

**Backends** consume the IR and live under `IR::Backends`, named for the platform they target (the ROM backend is `GBA`, not `Arm` — the target is the whole platform, not just the CPU). `Backends::Reference` runs the IR in Ruby (the headless test oracle — named for its role as the answer key, not for the language, since every backend here happens to be written in Ruby); `Backends::GBA` lowers it to a ROM; a `Backends::JS` could run it in a browser. All honor `IR::Int32`'s signed-32-bit semantics — that shared contract is what keeps them agreeing.

**Cross-backend rule:** a hardware feature (sound, tiles, sprites, paged modes…) isn't *done* until it works on every backend that needs it — the GBA lowering **and** the Ruby interpreter. The moment a feature is on the radar, write down each backend's slice as its own piece of work — even before the details are known — so it can't be forgotten while you're heads-down on the feature elsewhere. Don't lean on this principle to remember; record it.

**Conformance-fixture obligation:** a new IR feature (a `Node::CATEGORY` kind or a `binop` operator) isn't done until it's added to the kitchen-sink fixture in `test/conformance_fixture.rb`. That one program is run through every backend by `test/toolchain/ir/test_cross_backend_conformance.rb`; a backend missing a feature the fixture uses hits its "unsupported" branch and fails. The coverage test asserts the fixture touches every kind/operator, so a forgotten feature fails loudly — but only if you added it to the fixture. Hardware-only kinds (`raw` and `read_scanline` today) are exempt via `HARDWARE_ONLY_KINDS` and kept in an uncalled func. This guards *coverage*; the differential test (behavioral *agreement*) is separate.

### Key Patterns

- Variables are allocated in IWRAM (0x03000000+), 4 bytes each
- `r10`/`r11` are scratch registers for variable operations, `r12` for addresses
- Functions use `PUSH {lr}` / `POP {pc}` for call/return
- Conditionals emit inverse-condition branches to skip over blocks
- `case_var` reloads the variable before each comparison (scene calls clobber r10)
- Sound: channel 2 for beep/SFX, channel 1 for music (no conflicts)
- Music is played from the VBlank interrupt, not where `play_song` is written: the game only
  names the tune, and the player walks each part's event table in ROM once per real frame
- `debug_halt` truncates the ROM for bisecting issues

### Writing code comments

- Comments are for humans and should read as if a human wrote them.
- Be concise for ordinary code, but **explain the hardware generously**. The reader isn't
  assumed to know what VRAM, DMA, a page flip, or a palette is, so a few plain-language lines
  on *what the hardware is doing and why* are welcome — that teaching is the point.
- Do not name the issue tracker, or an issue id, in a code comment.
- **No measured decimals in a comment.** A scanline figure (`0.01928`, `0.0032`) or an
  accuracy ratio (`reads 1.12`) is specific to one emulator build and one moment, so it is
  stale as soon as anybody re-measures. Write what survives instead: **instruction counts and
  relationships**, which come from the emitted code, not from a timing run — "one instruction,
  not six", "clamping is twice wrapping", "a little over at an even column and a little under
  at an odd one". Those explain the code AND stay true. A measured number belongs somewhere
  dated by construction — a commit message, or the issue it came from.

### Writing commit messages

- Commit messages are for humans and should read as if a human wrote them.
- Be concise.
- Do not name the issue tracker, or an issue id, in a commit message. A `commit-msg` hook
  rejects one as a backstop; don't lean on it instead of just not writing it.
- Do not add a `Co-Authored-By` trailer. Do not say how many tests were added.
- Avoid AI "fluff" that sounds pleased with itself - be direct and get to the point.

### Writing user-facing errors and warnings — use the `simple-english` skill

When you write or change a guardrail finding, a DSL error message, or a validator
warning, run the text through the `simple-english` skill (ASD-STE100). Short
sentences, one idea each. Use one word for one meaning. Put the condition before
the command. Say what happened, then what to do about it, early. Prefer `can`,
`will`, and `must`; do not use `should`, `could`, or `may`. This rule applies to
strings the user reads. It does **not** apply to code comments — those stay
conversational and explain the hardware generously (see above). The friendly,
teaching tone stays; the skill only makes it clear and consistent.

### Claude Memory
- Don't use it, period. Material knowledge for RubyGBA goes in code comments
- Code style should be Rubocop or similar

### DSL Conventions

- `flip` (not `negate`) for reversing direction — reads naturally in game code
- `copy :dest, :src` for variable-to-variable assignment
- Underscore prefix (`_cpu_center`) for scratch/temp variables
- `func` for subroutines, `scene` for game states, `case_var` for dispatch

## Examples

`examples/` (26 programs). Most are cited inline in `.claude/rules/dsl-reference.md` next to
the verb they demonstrate. Two are flagship "putting it all together" showcases, grown as
features land rather than spawning one-feature-per-example demos:

- `examples/breakout.rb` — bitmap-mode flagship: collision, score, lives, scenes, sound, music
- `examples/pacman.rb` — tiled-mode flagship: maze background, hardware sprites, collision, sound, scenes

## Finishing a piece of work
- Commit it, and keep the message for humans — see "Writing commit messages" above.

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

## Task tracking with beads (`bd`)

Graph-based, agent-friendly tracker living with the project. This tracker's prefix is
**`gba-`**. Epics and children both have **flat ids** (e.g. `gba-xhu`) linked by
`parent-child` dependencies — we did *not* use hierarchical `--parent` ids.

Commands you'll use most:

```bash
bd ready --exclude-type epic      # the actionable queue (epics are just containers)
bd ready --json                   # structured — preferred when parsing
bd show gba-xhu                   # details; epics list their children + % complete
bd create "Title" -t task -p 1    # types: bug|feature|task|epic|chore|decision; -p 0(high)..4
bd update gba-0pn --claim         # claim (assign + in_progress), then start the work
bd update gba-0pn --acceptance '…' # set/replace AC after creation (no --acceptance-file; single-quote inline, no backticks/$)
bd dep add <blocked> <blocker>    # <blocked> depends on <blocker>  (arg order is the #1 gotcha)
bd dep tree gba-xhu               # visualize; run `bd dep cycles` after bulk wiring
bd close gba-0pn --reason "..."   # close when done
```

Notes learned in practice:

- Dependencies gate `bd ready` — a bead shows ready only once every bead it depends on
  is closed. Wire them as you plan; that's what makes `bd ready` mean "actually
  startable."
- When you claim a child, also claim its parent epic (`bd update <epic> --claim`) so the
  epic stops appearing in `bd ready`. Only close an epic once all its children are closed.
- Create **one issue per command** — don't chain many `bd create`s in one shell line;
  failures need to stay visible and recoverable.
- **Shell-safety (learned the hard way):** never pass `--reason`/`--description` text
  containing backticks, `$(...)`, or other shell metacharacters as an inline argument —
  the shell will execute it (this once dumped a live secret into the db). Write such text
  to a file and pass `--reason-file` / `--body-file` instead.
- Claiming a bead means starting it — proceed straight into the work. Only pause for real
  ambiguity (unclear requirements, a design call with no obvious answer) or a blocker.
- Never use `bd decision` - it will effectively be lost. decisions should instead be code, or code
  comments above relevant code.


## Shell commands — one operation per call

Run **one logical command per Bash call.** Do not chain distinct operations with `&&`, `;`,
or newlines in a single invocation, and do not bundle a file-writing heredoc
(`cat > f <<EOF …`) with the command that consumes it.

Why this is non-negotiable here: the operator reads each command before allowing it, and the
permission allow/denylist matches on recognizable prefixes (`git commit`, `rake test:parallel`,
`bd close`). A blob like `cat > msg <<EOF … EOF; git add .; git commit -F msg; git show` is
unreadable, can't be allowlisted, and can't be denied granularly.

- `git add`, then `git commit`, then `git show` are **three separate Bash calls**, not one.
  Need several commands at once? Issue several Bash calls (they can run in parallel) — each
  stays individually matchable.
- Write files — commit messages, scripts, bead bodies — with the **Write/Edit tools**, never
  `cat >`/heredocs. Then a single command reads the file (`git commit -F <file>`,
  `bd close --reason-file <file>`).
- No `python3 -c '…'` / `ruby -e '…'` logic one-liners. Put logic in a file so it's
  inspectable and re-runnable.
- Prefer one clear command over a clever pipeline, even for read-only inspection.


## Emulator & integration tests

Integration tests run ROMs in an emulator via **ruby-gba-emulator** — a lean, headless libmgba
probe. It is a **gem of its own**, living in this repository under `ruby-gba-emulator/`, and it
is reached through the one seam, `RubyGBA::Emulator` (`lib/ruby_gba/emulator.rb`), so nothing
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
rake test TEST=test/test_thing.rb                               # one file
rake test TEST=test/test_thing.rb TESTOPTS="--name=/pattern/"   # one test
```

See `.claude/rules/testing.md`.

The framework's largest consumer, a Wolfenstein 3D port, lives in its own repository at
`~/open_source/ruby-wolf3d` and depends on this one as a gem. It has a suite of its own which
this one does not run and must not learn about: a library that names the games built on it is
coupled to them. Its whole purpose is to find gaps here — a bead it raises against the
framework is filed in THIS tracker. To work on both at once, point its bundler at this
checkout (`bundle config --local local.ruby-gba ../ruby-gba` from there).

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
    by frame. `test/test_dsl_expression.rb` is the worked example.
  - **Hardware path: the emulator** runs the real ROM and reads real pixels/audio
    (`assert_emulator_loads_rom` → `Verifier`). Keep a couple per feature to confirm
    the lowering; they fail loudly when the emulator is absent.
  - Supply input through the interpreter's `hold(:btn)` / `input_each_frame { }`
    and the emulator's `keys:`, not by poking internal state.
  - Guardrail tests are behavioral too: assert the *friendly error* a misuse
    raises (a dropped `.then`, an unknown button) — the class and a key phrase,
    not the wording verbatim.

- **IR backend level — opcodes and lowering are fair game.** Here the generated
  code *is* the contract, so `test/test_ir_backend_gba.rb` may assert the two-pass
  jump math, register conventions, or instruction shapes, and
  `test/test_ir_backend_ruby.rb` asserts interpreter state. These build hand-made
  `IR::Build` trees (not the DSL) because they test the backend, not the surface.

- **Cross-backend:** a feature isn't done until it's tested on every backend it
  touches — the GBA lowering *and* the Ruby interpreter (see the cross-backend
  rule under Codegen IR).

## Architecture

### Core Files

- `lib/ruby_gba/builder.rb` — The DSL entry point (`Builder`). Thin now: it `require`s and
  `include`s one concern module per area from `lib/ruby_gba/builder/` (19 files), each
  owning a slice of the flat verb surface — `randomness`, `sound`, `music`, `text`,
  `images`, `sprites`, `sprite_import`, `input`, `drawing`, `variables`, `control_flow`,
  `scenes`, `collision`, `tiled`, `composition`, `timers`, `sampled_audio`, `layers`. Every
  verb builds a node in an IR tree and returns; nothing here emits ARM (see "Codegen IR").
- `lib/ruby_gba/asm.rb` — ARM7TDMI instruction encoding (MOV, LDR, STR, branch, etc), used
  by the GBA lowering backend and by the `entry` escape hatch's raw-instruction context.
- `lib/ruby_gba/ir/` — Intermediate representation: a plain-Ruby op-tree the DSL builds instead of emitting target code directly. `node.rb` (`IR::Node`), `build.rb` (readable constructors). See "Codegen IR" below.
- `lib/ruby_gba/rom.rb` — ROM buffer management, header, finalization
- `lib/ruby_gba/constants.rb` — GBA hardware register addresses and flags
- `lib/ruby_gba/music.rb` — Music DSL (`SongContext`, note frequencies, duration math). Channel 1 for music, channel 2 for SFX
- `lib/ruby_gba/color.rb` — 15-bit BGR555 color handling, named presets
- `lib/ruby_gba/font.rb` — Bitmap font model (glyphs + metrics); built-in fonts registered in `fonts.rb`
- `lib/ruby_gba/rom_validator.rb` — ROM validation (header, checksum, structural checks) — `ROMValidator`
- `lib/ruby_gba/inspector.rb` — ROM disassembly and header reporting
- `lib/ruby_gba/verifier.rb` — Pixel-level verification via libmgba (through the `RubyGBA::Emulator` seam → ruby-gba-emulator)
- `lib/ruby_gba/emulator.rb` — The one seam to the emulator backend; swap emulators here
- `lib/ruby_gba/test_patterns.rb` — Built-in test ROMs (solid fill, color bars, etc)

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

**Cross-backend rule:** a hardware feature (sound, tiles, sprites, paged modes…) isn't *done* until it works on every backend that needs it — the GBA lowering **and** the Ruby interpreter. The moment a feature is on the radar, create a bead for each backend's slice — even before the details are known — so it can't be forgotten while you're heads-down on the feature elsewhere. Don't lean on this principle to remember; make the bead.

**Conformance-fixture obligation:** a new IR feature (a `Node::CATEGORY` kind or a `binop` operator) isn't done until it's added to the kitchen-sink fixture in `test/conformance_fixture.rb`. That one program is run through every backend by `test/test_cross_backend_conformance.rb`; a backend missing a feature the fixture uses hits its "unsupported" branch and fails. The coverage test asserts the fixture touches every kind/operator, so a forgotten feature fails loudly — but only if you added it to the fixture. Hardware-only kinds (`raw` and `read_scanline` today) are exempt via `HARDWARE_ONLY_KINDS` and kept in an uncalled func. This guards *coverage*; the differential test (behavioral *agreement*) is separate.

### Key Patterns

- Variables are allocated in IWRAM (0x03000000+), 4 bytes each
- `r10`/`r11` are scratch registers for variable operations, `r12` for addresses
- Functions use `PUSH {lr}` / `POP {pc}` for call/return
- Conditionals emit inverse-condition branches to skip over blocks
- `case_var` reloads the variable before each comparison (scene calls clobber r10)
- Sound: channel 2 for beep/SFX, channel 1 for music (no conflicts)
- Music uses unrolled frame comparisons (each note = if_eq on a frame counter)
- `debug_halt` truncates the ROM for bisecting issues

### Writing code comments

- Comments are for humans and should read as if a human wrote them.
- Be concise for ordinary code, but **explain the hardware generously**. The reader isn't
  assumed to know what VRAM, DMA, a page flip, or a palette is, so a few plain-language lines
  on *what the hardware is doing and why* are welcome — that teaching is the point.
- Do not mention beads in code comments. beads is internal to this machine (for now).
- **No measured decimals in a comment.** A scanline figure (`0.01928`, `0.0032`) or an
  accuracy ratio (`reads 1.12`) is specific to one emulator build and one moment, so it is
  stale as soon as anybody re-measures. Write what survives instead: **instruction counts and
  relationships**, which come from the emitted code, not from a timing run — "one instruction,
  not six", "clamping is twice wrapping", "a little over at an even column and a little under
  at an odd one". Those explain the code AND stay true. A measured number belongs in a commit
  message or a bead, which are dated by construction.

### Writing commit messages

- Commit messages are for humans and should read as if a human wrote them.
- Be concise.
- Do not mention beads in git commit messages comments. beads is internal to this machine (for now).
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

## Finishing a bead
- Commit changes to git, but keep the message for humans. Do not add the 'Co-authored ...' trailer. Do not mention how many tests were added.

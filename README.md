# ruby-gba

**A Ruby DSL that compiles to real Game Boy Advance ROMs — built as a teaching tool, and written end-to-end by AI.**

You write plain Ruby. `ruby-gba` turns it into an ARM7 cartridge that boots on a real GBA or any emulator. The guiding rule is simple: **you should need to know Ruby, not the hardware.** No VRAM, no DISPCNT, no ARM assembly, no "why is my screen black" — the framework manages the machine and turns the classic footguns into friendly, plain-language errors.

It is also an experiment in **AI-native tooling**: every line here was written by an AI agent, and the whole toolchain is shaped around giving an agent (and a human) fast, mechanical, readable feedback while building a game.

```ruby
require_relative "lib/ruby_gba"

# A trimmed slice — see examples/pong.rb for the full, heavily-commented game.
# (Constants like BALL_SPEED and vars like player_y/cpu_score are defined there.)
rom = RubyGBA.build("PONG", code: "BPNG", maker: "01") do
  display :bitmap
  enable_sound

  # `var` returns a handle you compare and mutate with the expression DSL.
  ball_x  = var :ball_x, 118
  ball_y  = var :ball_y, 78
  ball_dx = var :ball_dx, BALL_SPEED
  ball_dy = var :ball_dy, BALL_SPEED
  cpu_y   = var :cpu_y, 68
  state   = var :state, 0                # 0 = title, 1 = playing, ...

  func :update_ball do
    ball_x.add ball_dx
    ball_y.add ball_dy

    # A comparison IS a Condition; `.then` runs the block only when it holds.
    (ball_y <= 0).then { ball_dy.abs; beep :wall_bounce }

    # `&` composes comparisons into one overlap test (parenthesize each).
    hit = (ball_x >= LEFT_X) & (ball_x <= LEFT_X + PADDLE_W) &
          (ball_y >= player_y - BALL_SIZE) & (ball_y <= player_y + PADDLE_H)
    hit.then { ball_dx.abs; beep :paddle_hit }
  end

  scene :playing do
    clear_screen :black
    held(:up).then   { player_y.sub PADDLE_SPEED }     # hold a direction to move
    held(:down).then { player_y.add PADDLE_SPEED }
    cpu_y.approach ball_y - PADDLE_H / 2, CPU_SPEED     # AI slides toward the ball
    call :update_ball
    draw_rect_at :ball_x, :ball_y, BALL_SIZE, BALL_SIZE, :white
    draw_number cpu_score, 134, 8, :white, digits: 1    # live HUD score
  end

  game_loop do
    wait_vblank
    case_var :state do                   # dispatch on a state variable
      when_val 0, :title
      when_val 1, :playing
    end
  end
end

rom.write("pong.gba")   # guardrails run during build; rom.explain shows the cost tree
```

Build it and run it in any GBA emulator:

```bash
ruby examples/pong.rb      # => writes pong.gba
rake test                  # unit + (optional) emulator integration tests
```

---

## Design pillars

### Teaching tool first — hide the hardware

Every user-facing verb speaks intent and color *names*, never registers or jargon. `display :bitmap`, `draw_rect_at`, `beep :paddle_hit`, `clear_screen :black`. The framework owns the palette, VRAM layout, VBlank timing, and DMA. Sensible, safe defaults (edge-clipping, safe writes) mean nothing corrupts memory or silently fails — and a **raw escape hatch** stays available for anyone who *wants* to drop down to the metal.

### Guardrails — footguns become teaching errors

The worst part of learning the GBA is that mistakes rarely tell you *what* went wrong. A wrong register, a draw that runs off-screen, an 8-bit store into 16-bit-only memory — and you get a silent black screen, or garbled visuals, or memory corruption that surfaces somewhere unrelated, or a ROM that works in one emulator and hangs on real hardware. The failure is almost never next to its cause. So known footguns are caught at **build time** and explained in plain language: *drew something but never set a display mode*, *game loop that never waits for the screen*, *a draw that lands entirely off-screen*, *a comparison used as a native Ruby `if`*. Fatal problems stop the build so a broken ROM can't ship; advisories print and let it through. Fixes are **suggested, never silently applied** (opt-in `--auto-fix` is planned). The check registry is **extensible** — a feature or plugin can register its own guardrails.

### The value-centric DSL — why it matters

`var :ball_x, 118` returns a **handle**, and comparisons build a small expression tree rather than executing immediately:

```ruby
(ball_y <= 0).then { ... }                 # a Condition, not a Ruby `if`
hit = (ball_x >= LEFT_X) & (ball_y <= player_y + PADDLE_H)   # composed with &
cpu_y.approach ball_y - PADDLE_H / 2, CPU_SPEED              # arithmetic on handles
```

This matters because those handles and comparisons are **data the compiler can see**. `ball_y - PADDLE_H / 2` isn't run — it's recorded, so it can be validated, cost-estimated, optimized, and lowered to whatever the target needs. It also lets guardrails catch the `if`-instead-of-`.then` slip (a comparison used as a native Ruby `if` silently does nothing on hardware) and gives every operand one consistent, checkable shape.

### The IR — one description, many targets

The DSL does **not** emit ARM directly. Each verb builds a node in an in-memory **intermediate representation** (IR) — a plain-Ruby, inspectable op-tree. A separate pass validates it, then a **backend** consumes it: one *lowers* it to an ARM7 ROM, another *interprets* it in pure Ruby to a framebuffer (used for headless tests and as the reference oracle). A **cross-backend conformance fixture** keeps them honest against shared reference semantics (`IR::Int32`, signed 32-bit).

This adds a layer of machinery, and it earns it: forward references (branches, calls, scene jumps) resolve automatically in a two-pass lowering instead of hand-rolled offset math; whole-program passes like register allocation and constant-pooling become possible; guardrails inspect the whole program *before* a byte is emitted; and — the big one — **new targets are new backends, not a rewrite of the language.** Nodes are tagged **portable vs hardware-only**, which is what makes the future web/GBC targets tractable.

### Cost estimator + `rom.explain` — see the work

Because the program is inspectable, `ruby-gba` estimates how much *drawing* each frame does — in "write-units" — and exposes it as a structured tree (human-readable *and* JSON):

```ruby
rom.explain   # drill-down cost tree: which scene / func / loop draws the most per frame
```

This is both a **teaching aid** (understand why a frame is heavy) and a **debugging tool** (a guardrail can warn when a loop redraws the whole screen every frame). Cost profiles will eventually be parameterized per backend (GBA vs GBC).

### Future targets

The backend split is deliberate. Planned peers of the ARM backend, all reusing the same IR:

- **JavaScript / `<canvas>`** — ship a game to the web, plus an instant in-browser live preview.
- **Terminal (TTY)** — render the framebuffer as half-block ANSI; run a game in any terminal, even over SSH.
- **Game Boy Color** — an all-new lowering (8-bit SM83, tile/OAM/palette rendering). Large, but the architecture already supports adding it cleanly.

---

## Built by AI, for AI-assisted development

This entire tool is AI-written, and the workflow is designed so an agent can iterate safely and fast:

- **Tight, mechanical feedback loops.** The Ruby interpreter renders the IR headlessly (no emulator needed), a pixel Verifier reads back actual frames, guardrails give plain-language pass/fail at build time, and `rom.explain` emits a machine-readable cost tree an agent can reason over. An agent can build → validate → run → diff → explain without leaving Ruby.
- **Mechanical safety rails.** An IR verifier enforces the value model on every build (a malformed tree is a *library* bug, raised loudly); the conformance fixture diffs backends so a change can't silently break one target.
- **Persistent, cross-session memory.** Work is tracked in [**beads**](https://github.com/gastownhall/beads) (`bd`) — a dependency-aware issue graph living in the repo — so an agent can recover context, see what's ready, and pick up mid-stream across sessions. Agent guidance lives in `CLAUDE.md` / `AGENTS.md` (not currently committed to git)

---

## Feature progress

A rough map of the GBA surface. Checked = working today; unchecked = planned.

**Working**

- [x] Bitmap display — Mode 3, 240×160, 15-bit color
- [x] Drawing — pixels, rectangles, DMA fills, screen clear
- [x] Bitmap images + runtime `blit` (transparency, edge-clipping; ASCII-art or array)
- [x] Text + `draw_number` (built-in 5×7 font)
- [x] Value-centric expression DSL — `.then`/`.else`, `&`/`|`, integer division
- [x] Control flow — `func`/`call`, `scene`/`case_var`, `game_loop`, `repeat`
- [x] Input — D-pad + buttons (`held` / `pressed`)
- [x] Sound — two PSG channels (music + SFX): `song`, `beep`, `define_sound`
- [x] Deterministic randomness — `seed` / `roll` / `rand` / `chance` / `randomize`
- [x] Timing + motion — `every` / `after`, `approach`
- [x] Runtime collection — `list`
- [x] Guardrails (extensible registry) + build-time validation
- [x] Cost estimator + `rom.explain`
- [x] IR + two backends (GBA lowering, Ruby interpreter) with a conformance fixture + portability tagging

**Planned**

- [ ] Double-buffering (Mode 4/5 page-flip) + auto-managed palette
- [ ] Hardware sprites / OAM
- [ ] Tiled backgrounds & scrolling (Mode 0/1)
- [ ] VBlank-IRQ frame timing (retire the busy-wait)
- [ ] Sound completeness — 4 PSG channels + sampled PCM (Direct Sound)
- [ ] Asset pipeline — PNG → tiles / sprites / palette
- [ ] Screen effects — fade / shake / flash (camera + brightness primitives)
- [ ] More motion verbs — lerp / wrap / bounce / snap
- [ ] Plugin registries — register your own effect verbs and fonts
- [ ] Target-neutral draw layer (decouple draw intent from the framebuffer)
- [ ] Save / load persistence (SRAM / flash)
- [ ] CLI — `ruby-gba build` / `preview` / `doctor`
- [ ] JS / `<canvas>` backend (web target + live preview)
- [ ] Terminal (TTY) and Game Boy Color backends

---

## Project layout

```
lib/ruby_gba/
  builder.rb, builder/*      # the DSL surface, split by concern (drawing, input, sound, ...)
  value.rb, condition.rb     # the value-centric expression model
  ir/
    node.rb, build.rb        # the IR op-tree + constructors
    int32.rb, portability.rb # reference semantics; portable vs hardware-only tags
    guardrails/              # the check registry + individual footgun checks
    cost_model.rb            # per-frame draw-cost estimator (feeds rom.explain)
    backends/gba.rb          # lower IR -> ARM7 ROM
    backends/ruby/           # interpret IR -> framebuffer (headless reference)
  asm.rb, rom.rb             # ARM encoding + cartridge assembly
  verifier.rb                # read back real pixels from mGBA (optional, via gemba)
examples/                    # pong.rb, snake.rb, pixels.rb, sprite_mover.rb
```

## Status

Pre-1.0 and moving fast. Core bitmap games work end-to-end (see `examples/`); sprites, tiled modes, and the alternate backends are in progress. Building ROMs is **pure Ruby, no C extensions** — the optional pixel-level Verifier uses the `gemba` (mGBA) gem for emulator-backed tests, and integration tests skip gracefully without it.

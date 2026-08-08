# ruby-gba

**A Ruby DSL that compiles to real Game Boy Advance ROMs — built as a teaching tool, and written end-to-end by AI.**

You write plain Ruby. `ruby-gba` turns it into an ARM7 cartridge that boots on a real GBA or any emulator. The guiding rule is simple: **you should need to know Ruby, not the hardware.** No VRAM, no DISPCNT, no ARM assembly, no "why is my screen black" — the framework manages the machine and turns the classic footguns into friendly, plain-language errors.

It is also an experiment in **AI-native tooling**: every line here was written by an AI agent, and the whole toolchain is shaped around giving an agent (and a human) fast, mechanical, readable feedback while building a game.

![Snake, built entirely with the ruby-gba DSL, running in an emulator](assets/snake.gif)

> The game above is a complete Snake — growing body, random food, scoring, game-over — written in the DSL. Full source: [`examples/snake.rb`](examples/snake.rb).

```ruby
require_relative "lib/ruby_gba"

# A trimmed slice of examples/snake.rb — see that file for the full, commented game.
# (Grid constants like CELL, MIN_COL, BODY_CAP and the STEP beat are defined there.)
Snake = RubyGBA.game("SNAKE", code: "BSNK", maker: "01") do
  screen :bitmap
  enable_sound
  define_sound :eat, frequency: 880, duty: :quarter, decay: :fast

  # The snake's body is two parallel lists (xs[i], ys[i]), one entry per cell.
  # `list` is a bounded, runtime-sized collection — a ring buffer in IWRAM.
  xs = list :xs, capacity: BODY_CAP
  ys = list :ys, capacity: BODY_CAP

  var :state, 0
  dx = var :dx, 1
  dy = var :dy, 0
  food_x = var :food_x, 0
  food_y = var :food_y, 0
  score  = var :score, 0

  func :spawn_food do
    roll :food_x, MIN_COL..MAX_COL      # a deterministic PRNG stream (seed / roll / rand)
    roll :food_y, MIN_ROW..MAX_ROW
  end

  func :step_snake do
    hx = xs.last + dx                   # arithmetic on list cells + handles
    hy = ys.last + dy
    # Hit a wall -> game over; else grow a new head and either eat or slide forward.
    ((hx < MIN_COL) | (hx > MAX_COL) | (hy < MIN_ROW) | (hy > MAX_ROW)).then do
      state.set 2
      beep :die
    end.else do
      xs.push hx; ys.push hy
      draw_rect_at hx * CELL, hy * CELL, CELL, CELL, :white
      ((hx == food_x) & (hy == food_y)).then do    # ate the food: grow + score
        score.add 1; beep :eat; call :spawn_food
      end.else do
        xs.shift; ys.shift                          # slid forward: drop the tail
      end
    end
  end

  scene :playing do
    # Steer if the turn is perpendicular (the full file buffers it so you can't reverse).
    held(:up).then    { (dy == 0).then { dx.set 0; dy.set(-1) } }
    held(:right).then { (dx == 0).then { dx.set 1; dy.set 0 } }
    every(STEP) { call :step_snake }    # move on a beat, not every frame
  end

  game_loop do
    case_var :state do
      when_val 1, :playing              # title (0) + game_over (2) omitted — see full file
    end
  end
end

Snake.write_if_main   # `ruby snake.rb` writes snake.gba; guardrails run at build time
```

Build it and run it in any GBA emulator:

```bash
ruby examples/snake.rb             # => writes snake.gba
ruby-gba build examples/snake.rb   # the same, via the CLI (adds -o / --explain / --stats)
rake test                          # unit + (optional) emulator integration tests
```

---

## Design pillars

### Teaching tool first — hide the hardware

Every user-facing verb speaks intent and color *names*, never registers or jargon. `screen :bitmap`, `draw_rect_at`, `beep :eat`, `clear_screen :black`. The framework owns the palette, VRAM layout, VBlank timing, and DMA. Sensible, safe defaults (edge-clipping, safe writes) mean nothing corrupts memory or silently fails — and a **raw escape hatch** stays available for anyone who *wants* to drop down to the metal.

It also fixes the hardware defaults a real game has to fix and a first-timer never knows about. The console reads the cartridge at its slowest, safest speed at power-on, so every ROM asks for the quicker timing before it runs a line of your code — measured on the emulator's timing model, that is about **40% off the CPU time each frame** (breakout 17.4 → 10.6 scanlines of a 228-scanline frame, Pac-Man 13.5 → 8.0, the shmup 15.2 → 9.2). Pass `fast_cartridge: false` to keep the cautious timing.

### Guardrails — footguns become teaching errors

The worst part of learning the GBA is that mistakes rarely tell you *what* went wrong. A wrong register, a draw that runs off-screen, an 8-bit store into 16-bit-only memory — and you get a silent black screen, or garbled visuals, or memory corruption that surfaces somewhere unrelated, or a ROM that works in one emulator and hangs on real hardware. The failure is almost never next to its cause. So known footguns are caught at **build time** and explained in plain language: *drew something but never set a screen mode*, *game loop that never waits for the screen*, *a draw that lands entirely off-screen*, *a comparison used as a native Ruby `if`*. Fatal problems stop the build so a broken ROM can't ship; advisories print and let it through. Fixes are **suggested, never silently applied** (opt-in `--auto-fix` is planned). The check registry is **extensible** — a feature or plugin can register its own guardrails.

### The value-centric DSL — why it matters

`var :dx, 1` returns a **handle**, and comparisons build a small expression tree rather than executing immediately:

```ruby
(hy > MAX_ROW).then { state.set 2 }          # a Condition, not a Ruby `if`
ate = (hx == food_x) & (hy == food_y)        # comparisons composed with &
xs.push xs.last + dx                         # arithmetic on handles and list cells
```

This matters because those handles and comparisons are **data the compiler can see**. `xs.last + dx` isn't run — it's recorded, so it can be validated, cost-estimated, optimized, and lowered to whatever the target needs. It also lets guardrails catch the `if`-instead-of-`.then` slip (a comparison used as a native Ruby `if` silently does nothing on hardware) and gives every operand one consistent, checkable shape.

### The IR — one description, many targets

The DSL does **not** emit ARM directly. Each verb builds a node in an in-memory **intermediate representation** (IR) — a plain-Ruby, inspectable op-tree. A separate pass validates it, then a **backend** consumes it: one *lowers* it to an ARM7 ROM, another *interprets* it in pure Ruby to a framebuffer (used for headless tests and as the reference oracle). A **cross-backend conformance fixture** keeps them honest against shared reference semantics (`IR::Int32`, signed 32-bit).

This adds a layer of machinery, and it earns it: forward references (branches, calls, scene jumps) resolve automatically in a two-pass lowering instead of hand-rolled offset math; whole-program passes like register allocation and constant-pooling become possible; guardrails inspect the whole program *before* a byte is emitted; and — the big one — **new targets are new backends, not a rewrite of the language.** Nodes are tagged **portable vs hardware-only**, which is what makes the future web/GBC targets tractable.

### Effect packs — add verbs without touching the compiler

The DSL is extensible. A **pack** is a module of verbs you register, and from then on they're ordinary DSL verbs — a game writes them next to `fill_rect` and can't tell which is which:

```ruby
module Juice
  def flash_corner(color)          # plain DSL verbs, no receiver — like a `func` body
    fill_rect 0, 0, 20, 20, color
  end

  def self.checks = [MyCheck.new]  # the pack's own guardrails, active only while it's loaded
end

RubyGBA.register_effects(Juice)
RubyGBA::Effects.register(:wash) { |c| clear_screen c }   # or a single verb, inline
```

The one rule at the seam: **a pack composes public verbs; it never builds IR or touches hardware.** That isn't taste. A verb built from public verbs bottoms out in things every backend already runs, so it works on the console *and* in the reference interpreter the day you write it — no per-backend lowering, no conformance fixture to extend. Anything lower is **kernel** and gets baked in properly.

**Rule of thumb:** a kernel primitive is a new thing the machine can *do*; a pack is a new way to *use* what it already does. New capability → kernel. New convenience → pack. If writing it means opening a file under `ir/backends/`, it was never a pack. Effects tend to come in **pairs** across that line:

| kernel primitive | the pack on top of it |
|---|---|
| `camera` — move the whole picture | `shake_screen` — jitter it, then put it back |
| `fade` — blend the picture toward a color | `fade_in` / `fade_out` — walk the amount over frames |

Screen shake is the worked example, and it ships as a default pack. Moving the picture at all is kernel — `camera` is an IR node with a real lowering on each backend. *Shaking* is not: it's `camera` called with a jittering offset, four variables and a routine that runs each frame. So `shake_screen` lives in a pack written in the same verbs a game is, and neither backend knows the file exists — copy `lib/ruby_gba/effects/packs/screen_shake.rb` to write your own. The rule is enforced, not just documented: a test reads the pack sources and fails one that builds IR or names a hardware register.

### Cost estimator + `rom.explain` — see the work

Because the program is inspectable, `ruby-gba` works out what each frame costs — in **scanlines**, the console's own unit, so "45 of your 228" means something — and exposes it as a structured tree (human-readable *and* JSON):

```ruby
rom.explain   # drill-down cost tree: which scene / func / loop costs the most per frame
```

Every weight in it was **measured**, not guessed: a ROM that does one thing a known number of times, run on emulated hardware timing, differenced against one that does less of it. And each weight ships with the range it was measured over, so when your program asks it for an answer from well outside that range the report says so instead of answering confidently.

The estimate also has to face the measurement. When a real frame has been read, the report says **how much of it the breakdown accounts for** — because the failure mode of any cost model is silent: a cost missing from it entirely leaves both halves looking fine, and you spend an afternoon optimizing the biggest line in a breakdown that never had the real cost in it.

It is a **teaching aid** (understand why a frame is heavy, in terms of the verbs you wrote), a **guardrail** (it can warn that a loop redraws the whole screen every frame — the exact reason Snake draws incrementally), and a **build decision**: the estimate is what picks which routines to keep in the console's small pool of fast memory, where the same code runs quicker.[^fast] That choice has to be made while the ROM is still being built, before there is anything to measure — which is why an estimate earns its place next to a real emulator. With `gemba-core` installed the verdict is measured on top; without it, the report says "estimate only" and names what it could not price. Cost profiles will eventually be parameterized per backend (GBA vs GBC).

[^fast]: How much quicker, why, and how the build chooses what goes there: [`placement.rb`](lib/ruby_gba/ir/backends/gba/placement.rb). `rom.explain` prints what it chose and how much room is left.

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
- **A checked-in codebase map.** This project uses [understand-anything](https://github.com/Egonex-AI/Understand-Anything) to generate a map of the codebase, kept in `.ua/`.

---

## Feature progress

A rough map of the GBA surface. Checked = working today; unchecked = planned (tracked in `bd`).

**Working**

- [x] Bitmap display — Mode 3, 240×160, 15-bit color
- [x] Drawing — pixels, rectangles, DMA fills, screen clear
- [x] Bitmap images + runtime `blit` (transparency, edge-clipping; ASCII-art or array)
- [x] Text + `draw_number` (built-in 5×7 font)
- [x] Value-centric expression DSL — `.then`/`.else`, `&`/`|`, integer division
- [x] Control flow — `func`/`call`, `scene`/`case_var`, `game_loop`, `repeat`
- [x] Scenes / screens — a game is a state machine of scenes; each **owns what it draws** (a scene's sprites/HUD show only while it's active), plus per-scene display mode
- [x] Input — D-pad + buttons (`held` / `pressed`)
- [x] Double-buffering — tear-free Mode 4 page-flip (`screen :bitmap, tear_free: true`) + auto-managed palette
- [x] Hardware sprites / OAM — poses (`facing:`), flipbook animation (`frames:` / `rate:`), stacking, sprite/tile collision
- [x] Tiled backgrounds (Mode 0) — text or CSV maps, scrolling, stacked parallax layers
- [x] Sound — four PSG channels (music, SFX, noise, wave) + multi-voice songs (`song`/`voice`, `beep`, `noise`, `wave`)
- [x] Sampled PCM audio (Direct Sound / DMA sound) — `sample` / `instrument`, WAV import, mixer refilled once per frame
- [x] Deterministic randomness — `seed` / `roll` / `rand` / `chance` / `randomize`
- [x] Timing + motion — `every` / `after`, `approach`
- [x] VBlank-IRQ frame timing — `game_loop` paces itself at one pass per frame, sleeping the CPU on the BIOS interrupt wait rather than busy-waiting
- [x] Runtime collection — `list`
- [x] Save / load persistence — `save_var` over battery-backed SRAM, loaded at boot and re-saved on change
- [x] Asset pipeline — PNG → tiles / sprites / animation frames, and CSV tilemaps → backgrounds
- [x] Fonts — built-in + register your own (`font` from glyph art)
- [x] Guardrails (extensible registry) + build-time validation, findings traced to the DSL line
- [x] Effect packs — register your own DSL verbs (and their guardrails); `camera` + `shake_screen` ship as the first pack
- [x] Cost estimator + `rom.explain`
- [x] IR + two backends (GBA lowering, Ruby interpreter) with a conformance fixture + portability tagging
- [x] CLI — `ruby-gba build / inspect / new` (Thor): per-command help, typed options, friendly errors

**Planned**

- [ ] Affine transforms — rotation & scaling for sprites and backgrounds (Mode 7-style)
- [ ] Tiled TMX import + larger streamed maps (beyond one 32×32 screenblock)
- [ ] Opt-in guardrail auto-fix (`--auto-fix`)
- [ ] Screen effects — fade / flash (needs the brightness primitive)
- [ ] More motion verbs — lerp / wrap / bounce / snap
- [ ] Target-neutral draw layer (decouple draw intent from the framebuffer)
- [ ] Flash save memory (beyond SRAM)
- [ ] CLI `preview` — run a game in the browser (JS backend)
- [ ] JS / `<canvas>` backend (web target + live preview)
- [ ] Terminal (TTY) and Game Boy Color backends

---

## Examples

Every example under [`examples/`](examples/) is a complete, runnable game or demo
that teaches **one pattern** — the code *is* the documentation. Each file's header
comment explains the hardware it touches and, where there's a choice, *why it took
its approach over the alternatives*. Build any of them with `ruby examples/<name>.rb`
(or `ruby-gba build examples/<name>.rb`).

| Example | Teaches | How it draws |
|---|---|---|
| [`pong.rb`](examples/pong.rb) | Paddle/ball bounce, AABB `overlaps?` collision, scoring, music + SFX | Direct Mode 3, whole frame redrawn |
| [`breakout.rb`](examples/breakout.rb) | A whole grid of `overlaps?` bricks, lives, angle-on-paddle-hit | Tear-free (double-buffered), whole frame redrawn |
| [`snake.rb`](examples/snake.rb) | A growing `list` body, an `every` movement beat, live score | Direct Mode 3, **only the changed cells** redrawn |
| [`snake_buffered.rb`](examples/snake_buffered.rb) | The *same* game written the naïve way and still tear-free | Double-buffered, whole board redrawn each frame |
| [`pacman.rb`](examples/pacman.rb) | The tiled-mode flagship: a tiled room, `facing:` poses, sprite-to-sprite `overlaps?` (eat pellets, dodge a chasing ghost), a live on-screen SCORE (`draw_text`/`draw_number` in tiled mode), sound | Tiled background + hardware (OAM) sprites, HUD as glyph sprites |
| [`hero.rb`](examples/hero.rb) | A follow-you camera: a hardware sprite pinned to screen center while a world bigger than the screen scrolls under it (`background.scroll_to`) | Scrolling tiled background + a hardware sprite over it |
| [`sprite_mover.rb`](examples/sprite_mover.rb) | Steering a single sprite over a kept background | A software sprite over a preserved bitmap |
| [`animate.rb`](examples/animate.rb) | A flipbook `sprite` (`frames:` / `rate:`) — a spinning coin you can also walk | A software sprite cycling its frames on a hidden timer |
| [`tiles.rb`](examples/tiles.rb) | A room built from reusable 8×8 tiles + a text map (`tiles` / `background`) | Tiled background, drawn by the tile hardware |
| [`scroll.rb`](examples/scroll.rb) | Panning a camera over a world bigger than the screen (`background.scroll_by`, wraps at the edge) | Tiled background, scrolled by the tile hardware |
| [`parallax.rb`](examples/parallax.rb) | Two background layers (far clouds, near trees) scrolling at different speeds to fake depth | Stacked tiled layers, composited + independently scrolled |
| [`maze.rb`](examples/maze.rb) | A hero that walks corridors and is stopped by the walls (`tiles solid:`, `sprite.blocked_by`) | Tiled room + a hardware sprite with tile collision |
| [`sheet.rb`](examples/sheet.rb) | Art imported from PNG files: a tile sheet paints the room, a transparent sprite sheet animates the hero (`tiles from:` / `sprite frames_from:`) | Tiled room + a hardware sprite, both imported from images |
| [`level.rb`](examples/level.rb) | A level designed in a map editor: import the whole tile sheet as numbered tiles, then read the room straight from a CSV export (`tiles from:` / `background from:`) | Tiled room from a CSV tilemap + a hardware sprite |
| [`shmup.rb`](examples/shmup.rb) + [`shmup/`](examples/shmup) | A game **split across files** with real **scenes**: `player.rb`, `enemies.rb`, `hud.rb` are plain Ruby objects that take the build — no base class, no magic. Ship, diving enemies, per-pixel shot hits, a live HUD, and a **PLAYING → GAME OVER → restart** flow where losing the last ship hides the field and shows the game-over screen (no visibility flags) | Tiled: hardware sprites + text HUD + per-pixel collision, scene-scoped |
| [`jukebox.rb`](examples/jukebox.rb) | The sound showcase: three classical tunes written as plain notes (`song` / `note`) — Ode to Joy played two-handed with a `voice :melody` over a `voice :bass` — a cursor that picks one to play and loop, and bobbing "now playing" bars | Tear-free (double-buffered) bitmap menu |

Smaller demos round out the surface: [`pixels.rb`](examples/pixels.rb) (static
drawing), [`grid_cursor.rb`](examples/grid_cursor.rb) (a `grid` with a moving
cursor), [`buffered_bounce.rb`](examples/buffered_bounce.rb), and the font demos
[`fonts.rb`](examples/fonts.rb) / [`font_styles.rb`](examples/font_styles.rb) /
[`floating_digits.rb`](examples/floating_digits.rb).

### Scenes — a game is a state machine of screens

A real game has screens: a title, the game itself, a game-over card. Model each as a
`scene`, hold the current one in a variable, and `case_var` runs exactly one per frame:

```ruby
var :state, PLAYING

scene :playing do
  ship = sprite :ship, at: [112, 132]     # belongs to :playing
  draw_number :score, 46, 4, :yellow       # so does the HUD
  # ... move, shoot, collide ...
  (lives <= 0).then { set :state, GAME_OVER }
end

scene :game_over do
  draw_text "GAME OVER", 93, 68, :red       # shown only on this screen
  pressed(:start).then { set :state, PLAYING }
end

game_loop do
  case_var(:state) { when_val PLAYING, :playing; when_val GAME_OVER, :game_over }
end
```

The point: **a scene owns what it draws.** A sprite or HUD element declared inside a scene
is on screen only while that scene is active — so switching state switches the whole
screen, with no "hide this" flag anywhere. (Declare something at the top level instead and
it shows in every scene — a persistent HUD.) A scene can also be a class in its own file
(construct it inside its `scene` block) and can run in its own display mode. Worked
example: [`shmup.rb`](examples/shmup.rb) (PLAYING → GAME OVER → restart).

### Choosing how to draw a moving thing

The examples above deliberately solve the same kind of problem more than one way.
Which to reach for:

- **A sprite** (`sprite :hero, at: [x, y]`) — when a thing moves over a background
  you want to keep. The *same* handle works two ways, picked by the screen: on
  `screen :bitmap` it's a software sprite that saves and restores the pixels
  underneath (so it leaves no trail and you never clear the screen — but *don't* use
  one in a game that clears and repaints the whole screen every frame, since it
  repaints itself before your scene draws and the clear would wipe it; see
  `sprite_mover.rb`); on `screen :tiled` it's a hardware sprite the console
  composites over the background for free, which also stacks cleanly and has none of
  that clear-order caveat (see `pacman.rb`, `hero.rb`). Either way two sprites collide
  for free (`hero.overlaps?(coin)`), since each knows its own size.
- **A plain `box` + `draw_rect_at`** — when you already redraw the frame, or the
  thing isn't sprite-shaped. Collision is the same `overlaps?`. (see `pong.rb`, `breakout.rb`)
- **Redraw only what changed** — in direct Mode 3, repaint just the few cells that
  moved instead of the whole screen. The most work per frame, but it stays at 60fps
  and never tears. (see `snake.rb`)
- **Tear-free double-buffering** (`screen :bitmap, tear_free: true`) — when you'd
  rather just clear and repaint *everything* and not think about tearing, at the cost
  of frame rate if you draw a lot. (see `snake_buffered.rb`, `breakout.rb`)

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
  verifier.rb                # read back real pixels from an emulator (via gemba-core, the libmgba binding)
examples/                    # runnable games + demos (see the Examples section above)
assets/                      # captured GIFs / screenshots
```

## Status

Pre-1.0 and moving fast. Full games work end-to-end on both bitmap and tiled screens — sprites, scrolling backgrounds, four-channel sound, and the asset pipeline are all in (see `examples/`); sampled audio, affine transforms, and the alternate backends are the next frontier.

Building and shipping a ROM is **pure Ruby** — no compiler, no C extension. Anything that reads what a ROM *actually did* runs it in an emulator through **`gemba-core`**, a small in-repo C extension binding libmgba, which needs a C compiler and libmgba to build. Three things use it: the pixel read-back the tests assert on, the measured frame-rate verdict in `rom.explain`, and — the one that is easy to miss — **calibrating the cost model's weights**.

That last one is why the estimate works without it. Every number the cost model charges was measured through `gemba-core` on emulated hardware timing, once, by `tools/calibrate_cost_model.rb`, and committed as data (`lib/ruby_gba/ir/measured_weights.rb`). So the estimate is not a guess standing in for a measurement — it *is* a measurement, generalized and shipped. A pure-Ruby install gets hardware-calibrated cost feedback with no C toolchain; adding `gemba-core` gets you the live verdict for your own game on top, and `explain` says plainly which of the two you are reading. (How you install libmgba varies by platform, and most dev setups have a C compiler already.)

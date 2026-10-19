# DSL verb reference — the flat `RubyGBA.build` API

The verbs you call inside a `RubyGBA.build "NAME"` block (they mix into `Builder` from
`lib/ruby_gba/builder/*.rb`). **This file is the index**: a line per verb. The whole story of
each verb — every option, every friendly error, what it costs, the worked example — is in the
group file named at the head of its section, under `.claude/dsl/`. **Read that file before
using, changing or documenting a verb in it**: the lines here leave most of it out.

A **drift test** (`test/ruby_gba/test_dsl_reference.rb`) fails if a builder verb is missing
from this index or from every group file, or if this index grows past 40,000 characters. So
when you add a verb, add a line here and its whole story to its group file.

Conventions: coordinates are pixels, top-left origin, screen is 240×160. A `:symbol` names a
variable; an `Integer` is a literal; a `Value` (from `var`) is an expression.
`fill_rect`/`dma_fill_rect` need an **even width**; `draw_rect_at` takes any. Handles
(`Value`, `List`, `Grid`, `Sprite`, `Condition`/`Branch`) live in `lib/ruby_gba/dsl/` as
`RubyGBA::DSL::*`; their methods are listed with the verb that returns them.

**Mistakes that raise nothing** (each told in full in its group file):

- `flags |= 4` (and `hp + 1` alone) moves the Ruby name and leaves the game's variable as it was; write `flags.set! flags | 4`. (variables)
- A fraction divide that saturates and then has something added wraps very negative; give the divisor a floor (`d.clamp(NEAR, FAR)`), not the answer a ceiling. (variables)
- A `:byte` or `:half` slot keeps only the low bits: 200 in a `:byte` reads back as -56. (lists)
- `pressed` read inside `once_a_frame` fires once for each frame a late pass catches up; keep press tests in the loop. (control-flow)
- `pixelate_size == 16` and `iris_shut?` hold on two frames running; keep a flag of your own in the test. (drawing)
- On a tear-free screen a picture painted once flickers between two pages; use `keep_showing`. (drawing)

## Build / screen — `.claude/dsl/screen.md`

- `RubyGBA.game "NAME" do … end` — the name is all a cartridge needs; its four-character code is worked out from it (`code:`/`maker:` optional, a real cartridge's code refused). `stack_room:` sets the stack's bytes of quick memory (1024 by default, more for deep calls).
- `screen :bitmap` / `screen :bitmap, tear_free: true` / `screen :tiled` / `screen :rotozoom` — pick the display; per scene, and a turning background on `:tiled` is picked by the build. No `screen` line means `screen :bitmap`.
- `screen :bitmap, tear_free: true, colors: [...]` — give the colour table in an imported picture's own order.
- `screen :bitmap, tear_free: true, late: :show_now` (or a row, `late: 40`; `pace: 30` for a game aiming at thirty) — show a page finished too late at once instead of a frame later, at the cost of a tear; per scene, `:wait` by default.
- `setting :floors, 60` — a value handed to one build (`settings:`, `--set`), never read from the environment.
- `wait_vblank` — wait for the safe window to draw (a `game_loop` does it for you).
- `halt` — stop. `debug_halt` — truncate the ROM here, for bisecting.

## Drawing — `.claude/dsl/drawing.md`

- `pixel x, y, color` — one pixel.
- `fill_rect x, y, w, h, color` / `dma_fill_rect …` — a filled rectangle at fixed place, even width.
- `draw_rect_at x, y, w, h, color` — a rectangle whose place and size are worked out at run time, any width.
- `draw_column_at :picture, slice:, x:, top:, height:, width: 1` — one picture column stretched to a run-time height (a first-person wall, a scaled sprite).
- `clear_screen color` — the whole screen, or the area an `inside` holds.
- `inside x, y, w, h do … end` — clip everything drawn in the block to that rectangle (fixed edges, no nesting).
- `camera x, y` — move the visible window over a bitmap picture.
- `camera_follows hero, across: world` — tiled follow camera: the sprite stays put and the world slides.
- `fade :black, 50` — fade toward black or white, 0..100; `under: :layer` places it in the stack; `inside:`/`outside:` hold it to a rectangle. A fraction asks for 33 levels on a screen drawn through a colour table; a plain bitmap screen, a placed fade and a held fade keep 17.
- `tint :red, 30` — tint toward any colour; free on plain bitmap, a blend per declared colour elsewhere.
- `fade_out` / `fade_in` / `flash_screen` — the fade walked over time (`frames:`/`duration:`, any colour; `under:`).
- `fade_level` → `Value`, 0..100: how far the screen is faded now (wait on it to swap scenes).
- `pixelate 8` / `under:` — show the screen in blocks, 1..16.
- `pixelate_out` / `pixelate_in` — the blocks walked over time; `pixelate_size` → `Value`, the walk's block size now.
- `spotlight at:, radius:, dark:` → `Spotlight` — a light: picture inside a circle, darkened outside (tiled only, one per game).
- `iris_out at:` / `iris_in` / `iris_shut?` — a circle closing to black and opening again, on the game's light.
- `pulse sprite, to: 1.3` — a tiled sprite that grows and shrinks for ever.
- `keep_showing :name do … end` → handle with `.changed`, `.draw`, `.cancel` — a picture painted only when it changes, right on a two-page screen.
- `shake_screen intensity:, frames:` — shake on impact, then put the picture back.
- `grid :name, cols:, rows:, cell:, over:` → `Grid` with `set_cell` / `clear_cell`.

## Images & sprites — `.claude/dsl/sprites.md`

- `image :name, "." => :transparent, "#" => :red do … end` — ASCII art; or `width:/height:/data:`, or `from: "file.png"`.
- `image …, colors: [...]` — keep an imported picture's own colour order (see-through first); `colors: :list` names a declared list.
- `image …, colors: [...], places: [...]` — pixels as numbers into that list, which keeps a colour held at two places apart.
- `image :tag, from: list, width:, height:, colors:` + `tag.changed` — a sprite picture the game paints at run time.
- `colors :hurt, [...]` + `sprite.draw_with :hurt` (or a list with `showing:`, or `:own`) — draw a sprite from another colour list, by place.
- `recolor :slot, :goblin` (or a list with `showing:`, or `:own`) — change what colours a list holds at run time, so one group dresses many things.
- `mirror(:pic)` / `upside_down(:pic)` — the same picture turned; free in sprite memory on tiled.
- `blit :name, x, y` — draw a picture at a run-time place, clipped; `blit [:a, :b], x, y, showing: n` picks one by number.
- `sprite :name, at: [x, y]` → a sprite (software on bitmap, hardware on tiled): `x`/`y`, `move`, `move_to`, `clamp_to_screen`, `center_on_screen`, `face`, `hide`/`show`, `overlaps?`; `facing:`, `frames:` + `rate:`, `frames_from:`, `facing_from:`, `from_aseprite:` (+ `play`), `face [...], showing:`; tiled also `scale`, `face_angle`, `turn`, `angle`.
- Done for you, nothing to write: half-size art for 15 colours or fewer, poses stored at their own size, shared parts stored once, one frame kept in memory when a cast does not fit, pictures bigger than the console draws cut into pieces, still sprites not rewritten each frame.
- `rgb r, g, b` (0–31) / `rgb8 r, g, b` (0–255) / `color value` — make a 15-bit colour.

## Tiled backgrounds — `.claude/dsl/backgrounds.md`

- `tiles :name, "#" => :brick, solid: ["#"]` — a tileset; or `from: "sheet.png", tile: 8` (keyed cells, or every cell numbered).
- `tiles :box, from: list, count:, colors:` + `box.changed` — tiles the game paints at run time.
- `canvas :board, width:, height:, colors:` — a picture drawn into with words (`pixel`, `clear`, `fill_rect`, `blit`, `draw_letter`, `draw_text`, `draw_number`); `board.cells` for a map, `as: :sprite`.
- `background :name, tiles:, map:` → `Background` (or `from: "level.csv"`, Array rows, `walls:`) — declared once, drawn every frame; up to four at a time per screen.
- `bg.set_tile col, row, key` — change one cell at run time; `bg.cols` / `bg.rows`.
- `map: { hall: …, cave: … }` + `bg.show_map :cave` (or a number) — several maps, one showing; `showing`, `map_number`, `map_count`.
- `tiles: { area: :set }, map: { area: { … } }` — rooms in areas, each area's tiles brought in as it is walked into.
- `bg.draw_with :dusk` (list + `showing:`, a hash for a layer of several lists, `:own`) — recolour the whole layer by place.
- `bg.scroll_by dx, dy` / `bg.scroll_to x, y` — move the view over the map; maps bigger than the grid stream for you.
- `bg.scroll_each_row { |row| offset }` — bend each row sideways (water, haze).
- `bg.rotate degrees` / `bg.scale size` / `bg.angle` / `bg.turns_around x, y` — turn or resize the whole layer.
- Done for you: repeated and mirrored tiles stored once; each layer counts its tiles from its own start.

## Layers — `.claude/dsl/layers.md`

- `layers :sky, :world, :actors, :ui` — declare the stack once, back to front.
- `layer :name do … end` — what the block declares (backgrounds, sprites, pools with pictures, tiled text) sits at that depth.
- `layer :water, transparency: 40` / `shows:, shows_behind:` — see through this layer (tiled; one per screen).
- A layer holds things, not brushstrokes: painting verbs, `fade` and `camera` inside a `layer` are friendly errors.
- A scene is WHEN, a layer is WHERE; a background in front of a sprite needs every background and sprite to name a layer; four depth levels.
- `hero.put_in_layer :walking` (or a list + `showing:`) — a sprite that changes layer at run time.
- `draw_in_order hero, guard, guards` — sprites re-ordered each frame by a number: the bottom of each box unless a block says otherwise, highest in front unless `front: :lowest`. Whoever stands lower on screen is in front.

## Collision — `.claude/dsl/collision.md`

- `box x, y, w, h` → `Box`, a rectangle to test.
- `off_screen?`, `off_left?`, `off_right?`, `above_top?`, `below_bottom?` — edge tests on anything with bounds.
- `a.overlaps?(b)` → `Condition`; sprite against sprite is per pixel unless `hitbox:`.
- `sprite.blocked_by(background)` / `pool.blocked_by(bg)` / `can_move?` — tile walls stop `move`.

## Text & numbers — `.claude/dsl/text.md`

- `draw_text "HELLO", x, y, color, font:` — text; `[:gray, :white], showing: cond` for two colours.
- `draw_number :var, x, y, color, digits:, font:` — a live number, right-aligned.
- `:left` / `:center` / `:right` (with `within:`) in place of a column.
- `text_width "SCORE"` / `text_height` — sizes in pixels.
- On `screen :tiled` text is sprite glyphs, declared once above the loop or in a scene, and a test around it says when it shows.
- `font :name do glyph "A", … end` or `font :name, glyphs: {…}, blank:` — a font.

## Variables & math — `.claude/dsl/variables.md`

- `var :name, init` → `Value`, started once at boot; one name is one variable wherever declared (conflicting starts refused).
- `var :mode, :title` — a variable holding one of a set of names; `call mode` runs the routine of that name (all scenes, or no scene).
- `save_var :name, default` — survives power-off, saved for you.
- `save_data :file, copies: 3 do keep … end` — a save record: `files[n].save` / `.load` / `.erase` / `.state` / `.peek`, `copy`, `reset`, `saving?`, `finished?`, `failed?`, `when_busy:`, `fast:` (the save memory's size is the build's to pick, or `save_memory:` on `RubyGBA.game`); `Reference.save_into` and `save_vars_into` for tests.
- `saves_keep_everything except: [...]` — refuse a game whose save records leave state out.
- `set! :name, value` — assign. `add! :name, n` (alias `add_var!`) / `sub! :name, n` (alias `sub_var!`).
- `copy! :dest, :src`, `negate! :name` (alias `flip!`), `abs! :name`, `negate_abs! :name`.
- `clamp! :name, lo, hi`, `approach! :name, target, step` — bounds and step may be worked out at run time.
- A word without `!` never changes a variable. On a handle (`abs`, `clamp`, `approach`, `flip`, `negate_abs`) it is a new number, and alone on a line a friendly error. As a flat verb (`set`, `add`, `sub`, `add_var`, `sub_var`, `copy`, `negate`, `flip`, `abs`, …) it is always a friendly error naming the `!` word.
- Introspection: `variables`, `var_address :name`.
- Expressions on a `Value`: `+ - * / %`, unary `-`, comparisons → `Condition`, `&`/`|` on conditions, `.then { } .else { }`; an expression never kept is a friendly error.
- `estimate: { usually: N }` (on `list`, `pool`, `repeat`, `.then`, `draw_rect_at`, `draw_column_at`) does nothing: it is set aside, with one warning naming every line that gives one.
- Bits: `& | ^ ~ >> <<` for packed data; `%` wraps like Ruby; dividing by zero gives 1/-1 and `%` the number.
- Numbers with a fraction: write a Float (`var :px, 3.5`); `.to_i`, `.to_f`; fraction × fraction and ÷ are done at full width.

## Control flow — `.claude/dsl/control-flow.md`

- `game_loop do … end` — once a frame; the screen stays off until the first frame is set up. `frame_sync: :manual` to place `wait_vblank` yourself.
- `repeat(n) { |i| … }` (`stop_when:`) — a run-time counted loop.
- `every(n) { … }` / `every(0.5, :seconds)` — on a beat. `after(n) { … }` — once, n frames in.
- `once_a_frame { … }` — always runs, once for each frame that really passed (movement that keeps real time).
- `timer :name, per_second: N` → `Timer` with `ticks`, `on_tick`, `stop`.
- Low-level: `if_eq` / `if_ne` / `if_gt` / `if_lt` / `if_ge` / `if_le`, aliases `if_gte` / `if_lte`.

## Scenes & funcs — `.claude/dsl/scenes.md`

- `func(:name, fast:) { … }` + `call :name` — a routine, emitted once; the build picks what goes in quick memory, per scene when it does not all fit.
- `call [:a, :b], number: n` — one of several routines by a run-time number.
- `scene(:name, fast:) { … }` + `case_var(:state) do when_val 0, :title … end` — game states, one run per frame.
- `scene(:name, loads_first: true)` — the pass it takes over on puts its pictures up, and its work starts on the pass after: a big level's first frame does not run late.
- A scene owns what it draws: its sprites, text, backgrounds, colours and memory are up only while it runs, so the budgets are per scene.
- A scene may declare its own `screen`; a scene can be a class in its own file.
- `dump_func :name` — disassemble a func from the built ROM.

## Input — `.claude/dsl/input.md`

- `held(:left)` — 1 while down; `pressed(:start)` — 1 on the press edge. `:any` for any button.
- Low-level: `if_held(:a) { }` / `if_pressed(:a) { }`. Buttons: `a b select start right left up down r l`.

## Menus — `.claude/dsl/menus.md`

- `menu :name, at: [x, y] do |m| m.item("NEW GAME") { … } end` → `Menu` — rows, a wrapping cursor, a block per row; inside the loop or a scene.
- `m.item …, enabled:` (true, false or a test), `m.item [...], showing:` for a row whose words change; `starts_on:`, `spacing:`, `cursor:`, `press:`, `repeat_every:`; `m.picked`, `m.moved`, `m.length`.

## Lists — `.claude/dsl/lists.md`

- `list :name, capacity: N` → `List`: `push`/`<<`, `pop`, `shift`, `[]`, `[]=`, `first`, `last`, `length`, `each`, `fill`, `copy_from`; `holds: 0.0`, `width: :byte`/`:half`, `fast:`.

## Tables — `.claude/dsl/tables.md`

- `table :name, array, width:, signed:` → `Table`, read-only ROM data read by a run-time index (power-of-two lengths wrap cheaply).

## Pools — `.claude/dsl/pools.md`

- `pool :name, field: default, …, capacity: N` → `Pool`: `spawn`, `each` (oldest first, `newest_first:`), `remove`, `index`, `count`, `full?`; `on_full:`, `image:`/`facing:`/`frames:`, `widths:`, `pool.func(:name) { |g| … }`.

## Randomness — `.claude/dsl/randomness.md`

- `seed n` / `randomize`, `roll :var, 1..6`, `rand(1..6)`, `chance(25)`.
- `random_numbers` — the stream itself, for a save record to keep.

## Sound & music — `.claude/dsl/sound.md`

- `enable_sound`, `define_sound :name, frequency:, duty:, decay:, volume:`, `beep :tone` — square-wave effects.
- `noise :explosion` — a hit on the noise voice. `wave :triangle, :C4` / `stop_wave` — a tone on the wave voice (a name or 32 steps).
- `song(:name) { … }`, `play_song :name` (`this_frame:`), `stop_music` — music; `voice … plays:` for recordings, `:wave`, `:noise`; `loop_from_here`.
- `music_volume 50` / `music_volume` — how loud the music is; `fade_music_out` / `fade_music_in`.
- `sample :name, from: "clip.wav"` → `Sample` with `play` (`loop:`, `volume:`, `pitch:`) and `stop` — mixed recorded sound, up to 16 voices.
- `songs :music, [score, …]` → `SongList` (`play`, `stop`) — music as `Audio::Score` data; `plays_once:`, `loop_from:`, `low_notes_intended:`.
- `sound_effects :sfx, {…}` → `SoundEffectList` (`play`, `this_frame:`) — Scores played once over the song; `group:`, `priority:`.
- `instrument :piano, from:, note:, envelope:, holds_from:` → `Instrument` with `play` (notes, chords) and `stop`.

## Measuring a finished game — `.claude/dsl/measuring.md`

- `rom.profile` / `ruby-gba profile game.rb` — what the build chose and where the frames went; `keys:`, `scene:`, `from:` to reach the moment worth measuring.

## Playing a finished game with nobody at the controls — `.claude/dsl/playthroughs.md`

- `RubyGBA.playthrough "name" do … end` — a script (`press`, `hold`, `wait`, `wait_until`, `hold_until`, `moment`); `.play(cartridge)` with `save:`, `lead_in:`, `pictures_in:`; `.tape`; `.compare(ours, theirs)` with its settings; `write_side_by_side_picture`; `ruby-gba play` and `ruby-gba compare`.

## Escape hatch — `.claude/dsl/escape-hatch.md`

- `entry do … end` — raw ARM instructions for what the DSL can't express.

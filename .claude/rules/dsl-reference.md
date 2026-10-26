# DSL verb reference — the flat `RubyGBA.build` API

The verbs a `RubyGBA.game "NAME" do … end` block calls (mixed into `Builder` from
`lib/ruby_gba/builder/*.rb`). **This file is the index**: a line per verb, enough to find it.
Each verb's options, friendly errors, cost and worked example are in the group file its section
names, under `.claude/dsl/`. **Read that file before using, changing or documenting a verb**, and
grep `.claude/dsl/` for an option or handle method not named here.

A drift test (`test/ruby_gba/test_dsl_reference.rb`) fails if a builder verb is missing from
this index or from its section's group file. A new verb gets a few words here and its whole
story in the group file.

Coordinates are pixels from the top left of a 240×160 screen. A `:symbol` names a variable, an
Integer is a literal, a `Value` (from `var`) is an expression. Handles (`Value`, `List`,
`Sprite`, `Condition`…) are `RubyGBA::DSL::*` in `lib/ruby_gba/dsl/`.

**Mistakes that raise nothing** (each in full in its group file):

- `flags |= 4` (or `hp + 1` alone) changes only the Ruby name; write `flags.set! flags | 4`. (variables)
- A fraction divide that saturates, then has something added, wraps negative; floor the divisor (`d.clamp(NEAR, FAR)`). (variables)
- A `:byte`/`:half` slot keeps the low bits: 200 in a `:byte` reads -56. (lists)
- `pressed` inside `once_a_frame` fires once per caught-up frame; test presses in the loop. (control-flow)
- `pixelate_size == 16` and `iris_shut?` hold two frames running; keep a flag of your own. (drawing)
- A picture painted once on a tear-free screen flickers between pages (one page on the Color); use `keep_showing`. (drawing)

## Build / screen — `.claude/dsl/screen.md`

- `RubyGBA.game "NAME", consoles: %i[gba]` — the game and the consoles it is for (`%i[gba gbc]` for the Color too); `ruby-gba build` makes a cartridge for each. Its code is worked out from the name. `stack_room:`.
- `screen :bitmap` / `:tiled` / `:rotozoom` (`tear_free:`, `colors:`, `late:`, `pace:`) — the display, per scene; `:bitmap` by default.
- `screen_width` / `screen_height` — the screen the game is being built for, to lay it out from.
- `setting :floors, 60` — a value handed to one build (`settings:`, `--set`).
- `wait_vblank`, `halt`, `debug_halt` (truncate the ROM, for bisecting).

## Drawing — `.claude/dsl/drawing.md`

- `pixel`, `fill_rect` / `dma_fill_rect` (fixed place, even width), `draw_rect_at` (run-time, any width), `clear_screen`.
- `draw_column_at :pic, slice:, x:, top:, height:` — a picture column stretched to a run-time height.
- `inside x, y, w, h do … end` — clip to a rectangle. `camera x, y`; `camera_follows hero, across: world` (tiled).
- `fade :black, 50`, `tint :red, 30`; over time `fade_out` / `fade_in` / `flash_screen`; `fade_level` → 0..100.
- `pixelate 8`; over time `pixelate_out` / `pixelate_in`; `pixelate_size`.
- `spotlight at:, radius:, dark:` → a light (tiled, one per game); `iris_out` / `iris_in` / `iris_shut?`.
- `pulse sprite, to: 1.3`; `shake_screen intensity:, frames:`.
- `keep_showing :name do … end` — a picture painted only when it changes, right on a two-page screen.
- `grid :name, cols:, rows:, cell:, over:` → `Grid`.

## Images & sprites — `.claude/dsl/sprites.md`

- `image :name, "#" => :red do … end` — ASCII art, `data:`, `from: "file.png"`, or `from: list` painted at run time.
- `sprite :name, at: [x, y]` → `Sprite` (software on bitmap, hardware on tiled): moving, facing, frames, hitbox, turning.
- `blit :name, x, y` — a picture at a run-time place, clipped.
- `mirror(:pic)` / `upside_down(:pic)` — the picture turned.
- `colors :hurt, [...]` + `draw_with`; `recolor :slot, :goblin` at run time; `colors_in_use` (a hint).
- `picture_groups :rooms, {…}` + `show` — sprite pictures by room, so only the rooms up take sprite memory.
- `hide_sprites` — no sprite (tiled text included) on the next frame drawn; all back the frame after. Tiled screens only.
- `rgb r, g, b` (0–31), `rgb8` (0–255), `color value` — a 15-bit colour.

## Tiled backgrounds — `.claude/dsl/backgrounds.md`

- `tiles :name, "#" => :brick, solid: ["#"]` — a tileset; `from:` a sheet, or a list painted at run time.
- `canvas :board, width:, height:, colors:` — a picture drawn into with words.
- `background :name, tiles:, map:` → `Background`: set a tile, switch maps, recolour, scroll, bend rows, turn; four per screen.

## Layers — `.claude/dsl/layers.md`

- `layers :sky, :world, :ui` — the stack, back to front; `layer :name do … end` puts what it declares at that depth.
- `hero.put_in_layer`; `draw_in_order hero, guards` — sprites re-ordered each frame, lower on screen in front.

## Collision — `.claude/dsl/collision.md`

- `box x, y, w, h`; `off_screen?` and edge tests; `a.overlaps?(b)` (per pixel unless `hitbox:`); `blocked_by(background)`.

## Text & numbers — `.claude/dsl/text.md`

- `draw_text "HI", x, y, color`, `draw_number :var, x, y, color, digits:`; `:left`/`:center`/`:right` for a column.
- `text_width`, `text_height`; `font :name do glyph … end`. On `screen :tiled` text is sprite glyphs.

## Variables & math — `.claude/dsl/variables.md`

- `var :name, init` → `Value`; `var :mode, :title` holds a name, and `call mode` runs it.
- `save_var :name, default`; `save_data :file do keep … end` → save records; `saves_keep_everything except:`.
- `set!`, `add!`/`add_var!`, `sub!`/`sub_var!`, `copy!`, `negate!`/`flip!`, `abs!`, `negate_abs!`, `clamp!`, `approach!` — change a variable.
- Without `!` nothing changes: on a Value (`abs`, `clamp`, `approach`, `flip`, `negate_abs`) a new number; flat (`set`, `add`, `sub`, `add_var`, `sub_var`, `copy`, `negate`) a friendly error.
- On a Value: `+ - * / %`, comparisons → `Condition`, `&`/`|`, `.then { } .else { }`, bits; a Float makes a fraction. `estimate:` only warns.

## Control flow — `.claude/dsl/control-flow.md`

- `game_loop do … end` — once a frame. `repeat(n) { |i| … }`; `every(n)`, `after(n)`; `once_a_frame`.
- `each_pass(:name) { |job| … }` → `PassJob`; `timer :name, per_second:` → `Timer`.
- `frames_since_power_on` → a `Value`, real frames shown since power-on, setting up included.
- Low-level `if_eq` `if_ne` `if_gt` `if_lt` `if_ge` `if_le` (`if_gte`, `if_lte`).

## The date and time — `.claude/dsl/clock.md`

- `clock` → `Clock` (`hour` … `weekday`); ask `present?` and `set?` first; `set_to(year:, month:, day:, hour:, minute:)` sets it.

## Scenes & funcs — `.claude/dsl/scenes.md`

- `func(:name) { … }` + `call :name` (or `call [:a, :b], number: n`); `dump_func :name` disassembles one.
- `scene(:name) { … }` + `case_var(:state) do when_val 0, :title end` — game states; a scene owns what it draws.

## Input — `.claude/dsl/input.md`

- `held(:left)`, `pressed(:start)` (`:any`); low-level `if_held`, `if_pressed`. Buttons `a b select start right left up down r l`.

## Menus — `.claude/dsl/menus.md`

- `menu :name, at: [x, y] do |m| m.item("NEW GAME") { … } end` → `Menu`.

## Lists — `.claude/dsl/lists.md`

- `list :name, capacity: N` → `List`, an array the game changes (`holds:`, `width:`, `full_of:`).

## Tables — `.claude/dsl/tables.md`

- `table :name, array` → `Table`, read-only ROM data read by a run-time index.

## Pools — `.claude/dsl/pools.md`

- `pool :name, field: default, capacity: N` → `Pool`, many of one thing (`spawn`, `each`, `remove`, `pool.func`).

## Randomness — `.claude/dsl/randomness.md`

- `seed n`, `randomize`, `roll :var, 1..6`, `rand(1..6)`, `chance(25)`, `random_numbers`.

## Sound & music — `.claude/dsl/sound.md`

- `enable_sound`; `define_sound :name, …` + `beep :name`; `noise`, `wave` / `stop_wave`.
- `song(:name) { … }` + `play_song`, `stop_music`; `music_volume`, `fade_music_out` / `fade_music_in`.
- `sample :name, from: "clip.wav"` → `Sample`, recorded sound, mixed.
- `songs :music, [score, …]`, `sound_effects :sfx, {…}` — music and effects as `Audio::Score` data.
- `instrument :piano, from:, note:` → `Instrument`.

## Measuring a finished game — `.claude/dsl/measuring.md`

- `rom.profile` / `ruby-gba profile game.rb` — where the frames went; `rom.sprite_memory`.

## Playing a finished game with nobody at the controls — `.claude/dsl/playthroughs.md`

- `RubyGBA.playthrough "name" do … end` — scripted presses on a cartridge; `ruby-gba play`, `ruby-gba compare`.

## The Game Boy Advance — `.claude/dsl/game-boy-advance.md`

- `consoles: %i[gba]` — every verb works on the Advance; the page says where it has more to say.

## The Game Boy Color — `.claude/dsl/game-boy-color.md`

- `consoles: %i[gba gbc]`, `ruby-gba build --console gbc` — the game on a Color too; what every verb does there (works or refused).

## Effects a game writes — `.claude/dsl/effects.md`

- `uses MyPack` — a module of verbs written in the game's own verbs.

## Escape hatch — `.claude/dsl/escape-hatch.md`

- `entry do … end` — raw ARM instructions.

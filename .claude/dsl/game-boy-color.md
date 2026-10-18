# The Game Boy Color — what every verb does there

A game built for the Color too (`RubyGBA.game "NAME", consoles: %i[gba gbc]`, then
`ruby-gba build --format=gbc`) is the same game on a smaller machine: a 160×144 screen
(`screen_width`, `screen_height`), eight buttons, one background, forty sprites (ten on a
row of the screen), and lists of four colours. Every verb has one of three answers there,
decided once in `Console::GBCFeatures`:

- **works** — the same game, played the same way. The Game Boy Color lowering's run of
  `rake test` holds the cartridge to the interpreter on every frame.
- **degrades** — the build goes on and says, once, what will look different and why. The
  interpreter shows the same difference when it plays the game for the Color.
- **refused** — the build stops before anything is made, saying what the game asked for
  and what to use instead.

This file is `Console::GBCFeatures.reference` written out (`ruby tools/gbc_answers.rb`), and a
test fails when the two differ.

- `screen` — works: `screen :tiled` and `screen :bitmap` work. A painted (bitmap) screen is painted into tiles behind the scenes, and holds four colours at once: a game that paints with more is refused, naming them. `screen :rotozoom` degrades: the turning layer is shown as a plain one, never turned or resized.
- `setting` — works: the same as on the Advance.
- `screen_width` — works: 160 on a Game Boy Color.
- `screen_height` — works: 144 on a Game Boy Color.
- `wait_vblank` — works: the same as on the Advance.
- `halt` — works: the same as on the Advance.
- `debug_halt` — degrades: the game stops there, as `halt` does; the cartridge is not cut short.
- `game_loop` — works: the same as on the Advance.
- `once_a_frame` — works: the same as on the Advance.
- `every` — works: the same as on the Advance.
- `after` — works: the same as on the Advance.
- `repeat` — works: the same as on the Advance.
- `timer` — works: a timer ticks by the frame, as the interpreter counts it.
- `pixel` — works: the same as on the Advance.
- `fill_rect` — works: the same as on the Advance.
- `dma_fill_rect` — works: the same as on the Advance.
- `draw_rect_at` — works: the same as on the Advance.
- `draw_column_at` — works: the same as on the Advance.
- `clear_screen` — works: the same as on the Advance.
- `inside` — works: the same as on the Advance.
- `grid` — works: the same as on the Advance.
- `camera` — **refused**: a painted screen on a Game Boy Color is exactly the size of the screen, so there is no larger picture for `camera` to move over. Draw the part to show, or use a tiled background and `scroll_to`.
- `keep_showing` — works: a painted screen on a Game Boy Color is always shown whole, so a picture kept showing never tears.
- `fade` — works: `fade` and `tint` change the colours the console shows, not the picture, as on the Advance. `under:` works where it falls between the background and the sprites; `inside:` and `outside:` are refused, since a Game Boy Color cannot fade part of the screen.
- `tint` — works: the same as on the Advance.
- `fade_in` — works: the same as on the Advance.
- `fade_out` — works: the same as on the Advance.
- `flash_screen` — works: the same as on the Advance.
- `fade_level` — works: the same as on the Advance.
- `shake_screen` — works: the same as on the Advance.
- `pixelate` — degrades: a Game Boy Color cannot show the screen in blocks, so the picture stays sharp. `pixelate_size` still walks, so a scene change waiting on it happens on the same frame.
- `pixelate_in` — degrades: the picture stays sharp; the size still walks (see `pixelate`).
- `pixelate_out` — degrades: the picture stays sharp; the size still walks (see `pixelate`).
- `pixelate_size` — works: the same as on the Advance.
- `spotlight` — **refused**: a light darkens everything outside a circle, which needs the Advance's blending. Use `fade` to darken the whole screen.
- `iris_in` — **refused**: the iris is the game's light closing, which a Game Boy Color cannot draw (see `spotlight`). Use `fade_out` and `fade_in`.
- `iris_out` — **refused**: see `iris_in`.
- `iris_shut?` — **refused**: see `iris_in`.
- `pulse` — degrades: a Game Boy Color cannot resize a sprite, so a pulsing sprite is shown at its own size.
- `camera_follows` — works: the same as on the Advance.
- `image` — works: a sprite's picture holds three colours and see-through, and a background's tiles four colours, from lists of four; a picture with more is refused, naming its colours.
- `color` — works: the same as on the Advance.
- `rgb` — works: the same as on the Advance.
- `rgb8` — works: the same as on the Advance.
- `colors` — works: a list of colours holds four places on a Game Boy Color, the first see-through on a sprite.
- `recolor` — works: the same as on the Advance.
- `mirror` — works: the same as on the Advance.
- `upside_down` — works: the same as on the Advance.
- `blit` — works: on a painted screen, its colours counting towards the screen's four.
- `sprite` — works: a sprite is made of the console's 8×8 pieces, forty at once and ten on any one row of the screen. `scale`, `face_angle` and `turn` degrade: a Game Boy Color cannot turn or resize a sprite, so it is shown upright at its own size.
- `draw_in_order` — works: the same as on the Advance.
- `pool` — works: its sprites count towards the forty.
- `box` — works: the same as on the Advance.
- `tiles` — works: tiles of four colours each.
- `background` — works: one background at a time, on a grid of 32×32 cells, scrolled and changed as on the Advance; a second background showing at once is refused. `rotate` and `scale` degrade to the background shown unturned, and `scroll_each_row` to the rows unbent.
- `canvas` — works: its colours are four, as a background's tiles' are.
- `layers` — works: a layer holds a background or sprites; a background in front of a sprite works. `transparency:` is refused: a Game Boy Color cannot show one layer through another.
- `layer` — works: see `layers`.
- `draw_text` — works: painted on a painted screen; on a tiled one each letter is a sprite, so they count towards the forty, ten to a row.
- `draw_number` — works: see `draw_text`.
- `font` — works: the same as on the Advance.
- `text_width` — works: the same as on the Advance.
- `text_height` — works: the same as on the Advance.
- `menu` — works: see `draw_text` for what its rows are made of.
- `var` — works: a variable is the same 32-bit whole number as on the Advance.
- `save_var` — works: kept in the cartridge's battery-backed memory.
- `save_data` — works: kept in the cartridge's battery-backed memory.
- `saves_keep_everything` — works: the same as on the Advance.
- `set` — works: the same as on the Advance.
- `set!` — works: the same as on the Advance.
- `add` — works: the same as on the Advance.
- `add!` — works: the same as on the Advance.
- `add_var` — works: the same as on the Advance.
- `add_var!` — works: the same as on the Advance.
- `sub` — works: the same as on the Advance.
- `sub!` — works: the same as on the Advance.
- `sub_var` — works: the same as on the Advance.
- `sub_var!` — works: the same as on the Advance.
- `copy` — works: the same as on the Advance.
- `copy!` — works: the same as on the Advance.
- `negate` — works: the same as on the Advance.
- `negate!` — works: the same as on the Advance.
- `flip` — works: the same as on the Advance.
- `flip!` — works: the same as on the Advance.
- `abs` — works: the same as on the Advance.
- `abs!` — works: the same as on the Advance.
- `negate_abs` — works: the same as on the Advance.
- `negate_abs!` — works: the same as on the Advance.
- `clamp` — works: the same as on the Advance.
- `clamp!` — works: the same as on the Advance.
- `approach` — works: the same as on the Advance.
- `approach!` — works: the same as on the Advance.
- `list` — works: the same as on the Advance.
- `if_eq` — works: the same as on the Advance.
- `if_ne` — works: the same as on the Advance.
- `if_gt` — works: the same as on the Advance.
- `if_lt` — works: the same as on the Advance.
- `if_ge` — works: the same as on the Advance.
- `if_le` — works: the same as on the Advance.
- `if_gte` — works: the same as on the Advance.
- `if_lte` — works: the same as on the Advance.
- `func` — works: `fast:` means nothing on a Game Boy Color, which runs all of its code alike.
- `call` — works: the same as on the Advance.
- `scene` — works: see `func` for `fast:`.
- `case_var` — works: the same as on the Advance.
- `dump_func` — degrades: a Game Boy Color build has no ARM to list, so nothing is printed.
- `entry` — **refused**: `entry` is raw ARM for the Advance's processor, which a Game Boy Color does not have.
- `held` — works: the eight buttons a Game Boy Color has. `:l` and `:r` are refused: it has no shoulder buttons.
- `pressed` — works: see `held`.
- `if_held` — works: see `held`.
- `if_pressed` — works: see `held`.
- `seed` — works: the same as on the Advance.
- `randomize` — works: the same as on the Advance.
- `roll` — works: the same as on the Advance.
- `rand` — works: the same as on the Advance.
- `chance` — works: the same as on the Advance.
- `random_numbers` — works: the same as on the Advance.
- `enable_sound` — works: the same as on the Advance.
- `define_sound` — works: the same as on the Advance.
- `beep` — works: the same as on the Advance.
- `noise` — works: the same as on the Advance.
- `wave` — works: the same as on the Advance.
- `stop_wave` — works: the same as on the Advance.
- `song` — works: on the square, wave and noise voices. A part played on a recording (`voice ..., plays:`) is refused: a Game Boy Color cannot play recorded sound.
- `play_song` — works: the same as on the Advance.
- `stop_music` — works: the same as on the Advance.
- `music_volume` — works: the same as on the Advance.
- `fade_music_in` — works: the same as on the Advance.
- `fade_music_out` — works: the same as on the Advance.
- `songs` — works: see `song` for recordings.
- `sound_effects` — works: see `song` for recordings.
- `sample` — **refused**: a Game Boy Color has no way to play recorded sound. Use `song`, `beep`, `wave` or `noise`.
- `instrument` — **refused**: an instrument plays a recording, which a Game Boy Color cannot (see `sample`). Write the part for the square or wave voice.

## Not made yet

An answer above is what the Color does with a verb. The build for it is still growing, and
a game that reaches one of these steps is refused, naming the step, until it is made:

- the picture: `inside`, `camera`, `blit`, `blit_pose`, `draw_column_at`, `save_region`, `restore_region`, `scroll_rows`, `shade_outside`, `set_tile`, `show_map`, `background_colors`, `copy_tiles`, `copy_owed_tiles`, `pixelate`, `see_through`
- sound: `play_from_list`, `play_sound_effect`, `play_sample`, `stop_sample`
- timers: `timer_start`, `timer_stop`, `timer_ticks`, `on_timer`

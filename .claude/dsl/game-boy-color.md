# The Game Boy Color — what every verb does there

A game built for the Color too (`RubyGBA.game "NAME", consoles: %i[gba gbc]`, then
`ruby-gba build`, which makes both cartridges, or `--console gbc` for the Color's alone) is
the same game on a smaller machine: a 160×144 screen (`screen_width`, `screen_height`),
eight buttons, one background, forty sprites (ten on a row of the screen), and lists of
four colours. Every verb has one of two answers there, decided once in
`Console::GBCFeatures`:

- **works** — the same game, played the same way. The Game Boy Color lowering's run of
  `rake test` holds the cartridge to the interpreter on every frame.
- **refused** — the build stops before anything is made, naming the hardware the Color
  lacks and what to use instead. Nothing is shown differently: a game either plays the
  same on the Color or is refused there.

This file is `Console::GBCFeatures.reference` written out (`ruby tools/gbc_answers.rb`), and a
test fails when the two differ.

- `screen` — works: `screen :tiled` and `screen :bitmap` work. A painted (bitmap) screen is painted into tiles behind the scenes, and holds four colours at once: a game that paints with more is refused, naming them. `screen :rotozoom` is refused: a Game Boy Color cannot turn or resize a background.
- `setting` — works: the same as on the Advance.
- `screen_width` — works: 160 on a Game Boy Color.
- `screen_height` — works: 144 on a Game Boy Color.
- `wait_vblank` — works: the same as on the Advance.
- `halt` — works: the same as on the Advance.
- `debug_halt` — works: the game stops there, as `halt` does; the cartridge is not cut short.
- `game_loop` — works: the same as on the Advance.
- `once_a_frame` — works: the same as on the Advance.
- `each_pass` — works: a step that starts its own job again is refused for now: the Game Boy Color build cannot make a routine that calls itself yet.
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
- `camera` — works: a painted screen on a Game Boy Color is the size of the screen, so moving the view over it shows black past the picture's edge. To move over a bigger world, use a tiled background and `scroll_to`.
- `keep_showing` — works: a painted screen on a Game Boy Color is always shown whole, so a picture kept showing never tears.
- `fade` — works: `fade` and `tint` change the colours the console shows, not the picture, as on the Advance. `under:` works where it falls between the background and the sprites; `inside:` and `outside:` are refused, since a Game Boy Color cannot fade part of the screen.
- `tint` — works: the same as on the Advance.
- `fade_in` — works: the same as on the Advance.
- `fade_out` — works: the same as on the Advance.
- `flash_screen` — works: the same as on the Advance.
- `fade_level` — works: the same as on the Advance.
- `shake_screen` — works: the same as on the Advance.
- `pixelate` — **refused**: a Game Boy Color cannot show the screen in blocks: it has no mosaic. Use `fade_out` and `fade_in` to go from one screen to the next.
- `pixelate_in` — **refused**: see `pixelate`.
- `pixelate_out` — **refused**: see `pixelate`.
- `pixelate_size` — works: the same as on the Advance.
- `spotlight` — **refused**: a light darkens everything outside a circle, which needs the Advance's blending. Use `fade` to darken the whole screen.
- `iris_in` — **refused**: the iris is the game's light closing, which a Game Boy Color cannot draw (see `spotlight`). Use `fade_out` and `fade_in`.
- `iris_out` — **refused**: see `iris_in`.
- `iris_shut?` — **refused**: see `iris_in`.
- `pulse` — **refused**: a Game Boy Color cannot resize a sprite. Draw the sprite's sizes as poses and `face` them in turn.
- `camera_follows` — works: the same as on the Advance.
- `image` — works: a sprite's picture holds three colours and see-through, and a background's tiles four colours, from lists of four; a picture with more is refused, naming its colours.
- `color` — works: the same as on the Advance.
- `rgb` — works: the same as on the Advance.
- `rgb8` — works: the same as on the Advance.
- `colors` — works: a list of colours holds four places on a Game Boy Color, the first see-through on a sprite.
- `recolor` — works: the same as on the Advance.
- `colors_in_use` — works: the Game Boy Color build does not let lists take turns yet. So every list of colours that a scene's sprites draw with must fit in the console's eight lists.
- `mirror` — works: the same as on the Advance.
- `upside_down` — works: the same as on the Advance.
- `blit` — works: on a painted screen, its colours counting towards the screen's four.
- `sprite` — works: a sprite is made of the console's 8×8 pieces, forty at once and ten on any one row of the screen. `scale`, `face_angle` and `turn` are refused: a Game Boy Color cannot turn or resize a sprite. Draw the turns as poses.
- `draw_in_order` — works: the same as on the Advance.
- `pool` — works: its sprites count towards the forty.
- `box` — works: the same as on the Advance.
- `tiles` — works: tiles of four colours each.
- `background` — works: one background at a time, on a grid of 32×32 cells, scrolled and changed as on the Advance, and bent row by row with `scroll_each_row`. A second background showing at once is refused, and so are `rotate` and `scale`: a Game Boy Color cannot turn or resize a background.
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
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `dump_func` — **refused**: it lists the ARM a routine was made into, and a Game Boy Color has no ARM processor to list it for.
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

- the picture: `background_colors`, `copy_tiles`, `copy_owed_tiles`
- sound: `play_sound_effect`

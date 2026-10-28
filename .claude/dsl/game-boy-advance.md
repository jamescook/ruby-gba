# The Game Boy Advance — what every verb does there

A game built for the Advance (`VBlank.game "NAME", consoles: %i[gba]`, then
`vblank build`) has a 240×160 screen (`screen_width`, `screen_height`), ten buttons,
four backgrounds, 128 sprites and lists of sixteen colours. Every verb works there: the
verbs were written for the Advance first. The answers are decided in
`Console::AdvanceAnswers`, as every console's are, and the Game Boy Color's are in
`.claude/dsl/game-boy-color.md`.

This file is `Console::AdvanceAnswers.reference` written out (`ruby tools/console_answers.rb`),
and a test fails when the two differ.

- `screen_width` — works: 240 on a Game Boy Advance.
- `screen_height` — works: 160 on a Game Boy Advance.
- `status_bar` — works: the bar takes one of the four background layers. A game with a bar cannot also have a light, a fade held to part of the screen, or a fade under a layer, because these need the same part of the display.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `dump_func` — works: it lists the ARM a routine was made into.
- `entry` — works: raw ARM for the Advance's processor (`.claude/dsl/escape-hatch.md`).
- `held` — works: the ten buttons a Game Boy Advance has, the shoulder buttons `:l` and `:r` among them.
- `pressed` — works: see `held`.
- `if_held` — works: see `held`.
- `if_pressed` — works: see `held`.
- `rumble` — works: nothing is felt. A Game Boy Advance cartridge with a rumble motor is not made yet, so the game plays the same without it.

These work as their group files say:

`screen`, `setting`, `wait_vblank`, `halt`, `debug_halt`, `game_loop`, `once_a_frame`,
`frames_since_power_on`, `each_pass`, `every`, `after`, `repeat`, `timer`, `pixel`, `fill_rect`,
`dma_fill_rect`, `draw_rect_at`, `draw_column_at`, `clear_screen`, `inside`, `grid`, `camera`,
`keep_showing`, `fade`, `tint`, `fade_in`, `fade_out`, `flash_screen`, `fade_level`,
`shake_screen`, `pixelate`, `pixelate_in`, `pixelate_out`, `pixelate_size`, `spotlight`,
`iris_in`, `iris_out`, `iris_shut?`, `pulse`, `camera_follows`, `image`, `color`, `rgb`, `rgb8`,
`colors`, `recolor`, `colors_in_use`, `mirror`, `upside_down`, `blit`, `sprite`,
`draw_in_order`, `hide_sprites`, `picture_groups`, `pool`, `box`, `tiles`, `background`,
`canvas`, `layers`, `layer`, `draw_text`, `draw_number`, `font`, `text_width`, `text_height`,
`menu`, `var`, `save_var`, `save_data`, `clock`, `saves_keep_everything`, `set`, `set!`, `add`,
`add!`, `add_var`, `add_var!`, `sub`, `sub!`, `sub_var`, `sub_var!`, `copy`, `copy!`, `negate`,
`negate!`, `flip`, `flip!`, `abs`, `abs!`, `negate_abs`, `negate_abs!`, `clamp`, `clamp!`,
`approach`, `approach!`, `list`, `if_eq`, `if_ne`, `if_gt`, `if_lt`, `if_ge`, `if_le`, `if_gte`,
`if_lte`, `func`, `call`, `scene`, `case_var`, `seed`, `randomize`, `roll`, `rand`, `chance`,
`random_numbers`, `enable_sound`, `define_sound`, `beep`, `noise`, `wave`, `stop_wave`, `song`,
`play_song`, `stop_music`, `music_volume`, `fade_music_in`, `fade_music_out`, `songs`,
`sound_effects`, `sample`, `instrument`.

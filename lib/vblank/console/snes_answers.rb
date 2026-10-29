# frozen_string_literal: true

module VBlank
  module Console
    # WHAT EVERY VERB DOES ON A SUPER NINTENDO (Console::Answers says what an answer is).
    #
    # The Super Nintendo came out a decade before the Advance and is in many ways the bigger machine:
    # a 256×224 screen, 128 sprites, backgrounds of up to sixteen colours a tile from eight lists,
    # 128K of work memory and a sound chip that plays recordings on eight voices. What it lacks is
    # the Advance's painted screen (every picture is tiles), a sprite that turns or resizes, more
    # than one layer that turns, and the Advance's square, wave and noise voices.
    #
    # A GAME SAYS WHICH CONSOLES IT IS FOR (`VBlank.game "PONG", consoles: %i[gba snes]`), and is
    # laid out from `screen_width` and `screen_height` rather than from 240 and 160, so the same
    # game fills each screen.
    #
    # An answer here is what the console's hardware does. What the Super Nintendo's build does not
    # make yet is the lowering's own list (Backends::SNES::Lowering::NOT_LOWERED_YET), which the
    # page shows under its own heading and the build refuses by name.
    module SNESAnswers
      extend Answers

      PAGE = ".claude/dsl/super-nintendo.md"

      PLAIN = "the same as on the Advance."

      ANSWERS = Ractor.make_shareable({
        # --- building, the screen and settings ---
        screen: works("`screen :tiled` and `screen :bitmap` work. A Super Nintendo has no painted " \
                      "screen, so a painted (bitmap) screen is made of tiles internally. " \
                      "`tear_free: true` keeps one picture, because the picture is copied to the " \
                      "console whole before it shows. `screen :rotozoom` is refused: the build does " \
                      "not use the one layer a Super Nintendo can turn."),
        setting: works,
        screen_width: works("256 on a Super Nintendo."),
        screen_height: works("224 on a Super Nintendo."),
        wait_vblank: works,
        halt: works,
        debug_halt: works("the game stops there, as `halt` does; the cartridge is not cut short."),
        game_loop: works,
        once_a_frame: works,
        frames_since_power_on: works,
        each_pass: works,
        every: works,
        after: works,
        repeat: works,
        timer: works("a timer ticks by the frame, as the interpreter counts it."),

        # --- drawing on a painted screen ---
        pixel: works,
        fill_rect: works,
        dma_fill_rect: works,
        draw_rect_at: works,
        draw_column_at: works,
        clear_screen: works,
        inside: works,
        grid: works,
        camera: works("a painted screen is the size of the screen, so moving the view over it shows " \
                      "black past the picture's edge. To move over a bigger world, use a tiled " \
                      "background and `scroll_to`."),
        keep_showing: works("a painted screen is always shown whole, so a picture kept showing never tears."),

        # --- fades, tints and screen effects ---
        fade: works("`fade` and `tint` change the colours the console shows, not the picture. " \
                    "`inside:`, `outside:` and `under:` are refused: the build cannot fade part of the " \
                    "screen on a Super Nintendo."),
        tint: works,
        fade_in: works,
        fade_out: works,
        flash_screen: works,
        fade_level: works,
        shake_screen: works,
        pixelate: refused("a Super Nintendo's mosaic shows the backgrounds in blocks but not the " \
                          "sprites. Use `fade_out` and `fade_in` to go from one screen to the next."),
        pixelate_in: refused("see `pixelate`."),
        pixelate_out: refused("see `pixelate`."),
        pixelate_size: works,
        spotlight: refused("a light darkens everything outside a circle by degrees, and a Super Nintendo's " \
                           "colour maths only adds, subtracts or halves. Use `fade` to darken the whole screen."),
        iris_in: refused("the iris is the game's light closing (see `spotlight`). Use `fade_out` and `fade_in`."),
        iris_out: refused("see `iris_in`."),
        iris_shut?: refused("see `iris_in`."),
        pulse: refused("a Super Nintendo cannot resize a sprite. Draw the sprite's sizes as poses and " \
                       "`face` them in turn."),
        camera_follows: works,

        # --- pictures and sprites ---
        image: works("a sprite's picture holds fifteen colours and see-through, and a background's tiles " \
                     "sixteen colours, from lists of sixteen."),
        color: works,
        rgb: works,
        rgb8: works,
        colors: works("a list of colours holds sixteen places on a Super Nintendo, the first see-through " \
                      "on a sprite. The console holds eight lists for sprites and eight for backgrounds."),
        recolor: works,
        colors_in_use: works,
        mirror: works,
        upside_down: works,
        blit: works,
        sprite: works("a sprite is made of the console's 8×8 pieces, 128 sprites at once and 34 pieces on " \
                      "any one row of the screen. `scale`, `face_angle` and `turn` are refused: a Super " \
                      "Nintendo cannot turn or resize a sprite. Draw the turns as poses."),
        draw_in_order: works,
        hide_sprites: works("on the next frame, no sprite shows. On the frame after, every sprite shows where it is."),
        picture_groups: works,
        pool: works("its sprites count towards the 128."),
        box: works,

        # --- backgrounds and layers ---
        tiles: works("tiles of sixteen colours each."),
        background: works("two backgrounds at a time, scrolled and changed as on the Advance. `rotate` and " \
                          "`scale` are refused: the build does not use the one layer a Super Nintendo can turn."),
        status_bar: works("the bar is one of the two backgrounds."),
        canvas: works,
        layers: works("a layer holds a background or sprites. A layer of backgrounds can be half " \
                      "see-through, over a background that covers the whole screen: `transparency:` " \
                      "from 50 to 56, or `shows: 50, shows_behind: 50`. A Super Nintendo mixes one " \
                      "layer into another only by half, never by the Advance's sixteen steps, so other " \
                      "amounts are refused."),
        layer: works("see `layers`."),

        # --- text ---
        draw_text: works("painted on a painted screen; on a tiled one each letter is a sprite, so they " \
                         "count towards the 128, 34 pieces to a row."),
        draw_number: works("see `draw_text`."),
        font: works,
        text_width: works,
        text_height: works,
        menu: works("see `draw_text` for what its rows are made of."),

        # --- numbers and logic ---
        var: works("a variable is the same 32-bit whole number as on the Advance."),
        save_var: works("kept in 32K of battery-backed RAM on the cartridge. A cartridge with a Super FX chip " \
                        "cannot keep a save yet."),
        save_data: works("kept in 32K of battery-backed RAM on the cartridge. A cartridge with a Super FX chip " \
                         "cannot keep a save yet."),
        clock: refused("a Super Nintendo cartridge built here has no clock chip. Ask the player for the time " \
                       "on a screen of the game's own, if the game needs it."),
        saves_keep_everything: works,
        set: works, set!: works, add: works, add!: works, add_var: works, add_var!: works,
        sub: works, sub!: works, sub_var: works, sub_var!: works, copy: works, copy!: works,
        negate: works, negate!: works, flip: works, flip!: works, abs: works, abs!: works,
        negate_abs: works, negate_abs!: works, clamp: works, clamp!: works,
        approach: works, approach!: works,
        list: works,
        if_eq: works, if_ne: works, if_gt: works, if_lt: works, if_ge: works, if_le: works,
        if_gte: works, if_lte: works,
        func: works("`fast:` means nothing on a Super Nintendo, which runs all of its code alike."),
        call: works,
        scene: works("see `func` for `fast:`."),
        case_var: works,
        uses: works("a pack's verbs are verbs of the game's own, and each one has its answer here."),
        dump_func: refused("it lists the ARM a routine was made into, and a Super Nintendo has no ARM " \
                           "processor to list it for."),
        entry: refused("`entry` is raw ARM for the Advance's processor, which a Super Nintendo does not have."),

        # --- input ---
        held: works("the ten buttons the Advance has: a Super Nintendo controller has them all, and X and " \
                    "Y besides, which a game cannot read yet."),
        pressed: works("see `held`."),
        if_held: works("see `held`."),
        if_pressed: works("see `held`."),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works,
        define_sound: works("a Super Nintendo has no square voice: its sound chip plays recordings, so the " \
                            "square is played as a recording of one. The sound chip cannot make a note above " \
                            "16000 Hz, so a higher note plays at 16000 Hz."),
        beep: works("see `define_sound`."),
        noise: works("a hiss is played on the sound chip's own noise. The sound chip has no metallic noise, " \
                     "so a metallic hit is played as a recording of one. The sound chip's noise is at most " \
                     "32000 steps a second, so a :high hiss is lower than on the Game Boy Advance."),
        wave: works("a Super Nintendo has no wave voice: its sound chip plays recordings, so it plays each " \
                    "waveform as a recording. A note above 4000 Hz plays at 4000 Hz."),
        stop_wave: works,
        song: works("see `define_sound` for the square and wave voices."),
        play_song: works,
        stop_music: works,
        music_volume: works,
        fade_music_in: works,
        fade_music_out: works,
        songs: works("see `song`."),
        sound_effects: works("see `song`."),
        sample: works("each recording plays on a voice of the sound chip. The sound chip has four voices for " \
                      "recordings. If four recordings play, a fifth recording is not heard. It still ends or loops " \
                      "as on the Advance."),
        instrument: works("see `sample`.")
      })

      # WHAT .claude/dsl/super-nintendo.md SAYS: every answer, in the order ANSWERS gives them, and
      # what the Super Nintendo's build does not make yet — +not_yet+, the lowering's own list of the
      # program's kinds it refuses for now, by what they are part of (Kit#answers_page).
      def self.reference(not_yet: {})
        <<~MARKDOWN
          # The Super Nintendo — what every verb does there

          A game built for the Super Nintendo too (`VBlank.game "NAME", consoles: %i[gba snes]`, then
          `vblank build`, which makes a cartridge for each console, or `--console snes` for the Super
          Nintendo's alone) is the same game on another machine: a 256×224 screen (`screen_width`,
          `screen_height`), 128 sprites (34 pieces on a row of the screen), backgrounds of tiles, and
          lists of sixteen colours. Every verb has one of two answers there, decided once in
          `Console::SNESAnswers`:

          - **works** — the same game, played the same way. The Super Nintendo lowering's run of
            `rake test:all` holds the cartridge to the interpreter after every pass.
          - **refused** — the build stops before anything is made, naming the hardware the Super
            Nintendo lacks and what to use instead. Nothing is shown differently.

          This file is `Console::SNESAnswers.reference` written out (`ruby tools/console_answers.rb`),
          and a test fails when the two differ. The Advance's answers are in
          `.claude/dsl/game-boy-advance.md`.

          #{answer_lines.join("\n")}

          ## Not made yet

          #{not_yet_words(not_yet)}
        MARKDOWN
      end

      # What the page says of the steps the Super Nintendo's build does not make yet.
      def self.not_yet_words(not_yet)
        return "The build for the Super Nintendo makes every kind of step that the answers above do not refuse." if
          not_yet.empty?

        "An answer above is what the Super Nintendo does with a verb. The build for it is still growing,\n" \
          "and a game that reaches one of these steps is refused, naming the step, until it is made:\n\n" +
          not_yet.map { |part, kinds| "- #{part}: #{kinds.map { |kind| "`#{kind}`" }.join(', ')}" }.join("\n")
      end
    end
  end
end

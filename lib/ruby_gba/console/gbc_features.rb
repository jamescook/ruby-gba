# frozen_string_literal: true

module RubyGBA
  module Console
    # WHAT EVERY VERB DOES ON A GAME BOY COLOR, decided once and written down here, where the build
    # checks and the reference both read it.
    #
    # The Game Boy Color is a much smaller machine than the Advance: a 160×144 screen, one background
    # layer, forty sprites (ten to a line) of four colours each, no way to turn or resize a layer,
    # to see one layer through another, or to play a recording. A game written for the Advance is
    # mostly made of things it CAN do — tiles, sprites, the square, wave and noise voices, which the
    # Advance inherited from it — and the rest gets one of three answers:
    #
    # - :works — the same game, played the same way. The checked run holds the cartridge to the
    #   interpreter on every frame, so this is a promise the test suite keeps.
    # - :degrades — the build goes on and says, once, in plain words, what will look different
    #   and why. The difference is a defined one (a turned layer is shown unturned), and the
    #   interpreter shows the same difference when it plays the game for a Game Boy Color, so the
    #   two still agree pixel for pixel.
    # - :refused — the build stops before anything is made, saying what the game asked for and
    #   what to use instead. A feature is refused rather than degraded when what is left would no
    #   longer be the game: a recording that plays as silence, a light that never falls.
    #
    # The north star decides between the last two: a teaching tool never ships a silent black
    # screen, so when the console cannot do a thing and there is no honest lesser version of it,
    # the author hears about it while building, not while playing.
    #
    # A GAME SAYS WHICH CONSOLES IT IS FOR (`RubyGBA.game "PONG", consoles: %i[gba gbc]`), and is
    # built for the Advance alone unless it says so. A game written for a 240×160 screen that is
    # built for a 160×144 one has a third of its picture cut away, which no warning would make
    # right; so reaching the second console is a decision the author makes once, in the game's
    # first line, having read the screen's size from the builder (`screen_width`, `screen_height`)
    # rather than writing 240 and 160.
    #
    # Every verb a game can write is in ANSWERS, which a test holds against the builder: a new verb
    # has no Game Boy Color answer until somebody decides one. The words are what the build says,
    # and what the reference shows beside the verb.
    module GBCFeatures
      Answer = Data.define(:verdict, :words) do
        def works? = verdict == :works
        def degrades? = verdict == :degrades
        def refused? = verdict == :refused
      end

      VERDICTS = %i[works degrades refused].freeze

      def self.works(words = "the same as on the Advance.") = Answer.new(:works, words)
      def self.degrades(words) = Answer.new(:degrades, words)
      def self.refused(words) = Answer.new(:refused, words)

      ANSWERS = Ractor.make_shareable({
        # --- building, the screen and settings ---
        screen: works("`screen :tiled` and `screen :bitmap` work. A painted (bitmap) screen is " \
                      "painted into tiles behind the scenes, and holds four colours at once: a game " \
                      "that paints with more is refused, naming them. `screen :rotozoom` degrades: " \
                      "the turning layer is shown as a plain one, never turned or resized."),
        setting: works,
        screen_width: works("160 on a Game Boy Color."),
        screen_height: works("144 on a Game Boy Color."),
        wait_vblank: works,
        halt: works,
        debug_halt: degrades("the game stops there, as `halt` does; the cartridge is not cut short."),
        game_loop: works,
        once_a_frame: works,
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
        camera: refused("a painted screen on a Game Boy Color is exactly the size of the screen, so " \
                        "there is no larger picture for `camera` to move over. Draw the part to show, " \
                        "or use a tiled background and `scroll_to`."),
        keep_showing: works("a painted screen on a Game Boy Color is always shown whole, so a picture " \
                            "kept showing never tears."),

        # --- fades, tints and screen effects ---
        fade: works("`fade` and `tint` change the colours the console shows, not the picture, as on " \
                    "the Advance. `under:` works where it falls between the background and the " \
                    "sprites; `inside:` and `outside:` are refused, since a Game Boy Color cannot " \
                    "fade part of the screen."),
        tint: works,
        fade_in: works,
        fade_out: works,
        flash_screen: works,
        fade_level: works,
        shake_screen: works,
        pixelate: degrades("a Game Boy Color cannot show the screen in blocks, so the picture stays " \
                           "sharp. `pixelate_size` still walks, so a scene change waiting on it " \
                           "happens on the same frame."),
        pixelate_in: degrades("the picture stays sharp; the size still walks (see `pixelate`)."),
        pixelate_out: degrades("the picture stays sharp; the size still walks (see `pixelate`)."),
        pixelate_size: works,
        spotlight: refused("a light darkens everything outside a circle, which needs the Advance's " \
                           "blending. Use `fade` to darken the whole screen."),
        iris_in: refused("the iris is the game's light closing, which a Game Boy Color cannot draw " \
                         "(see `spotlight`). Use `fade_out` and `fade_in`."),
        iris_out: refused("see `iris_in`."),
        iris_shut?: refused("see `iris_in`."),
        pulse: degrades("a Game Boy Color cannot resize a sprite, so a pulsing sprite is shown at its " \
                        "own size."),
        camera_follows: works,

        # --- pictures and sprites ---
        image: works("a sprite's picture holds three colours and see-through, and a background's tiles " \
                     "four colours, from lists of four; a picture with more is refused, naming its " \
                     "colours."),
        color: works,
        rgb: works,
        rgb8: works,
        colors: works("a list of colours holds four places on a Game Boy Color, the first see-through " \
                      "on a sprite."),
        recolor: works,
        mirror: works,
        upside_down: works,
        blit: works("on a painted screen, its colours counting towards the screen's four."),
        sprite: works("a sprite is made of the console's 8×8 pieces, forty at once and ten on any one " \
                      "row of the screen. `scale`, `face_angle` and `turn` degrade: a Game Boy Color " \
                      "cannot turn or resize a sprite, so it is shown upright at its own size."),
        draw_in_order: works,
        pool: works("its sprites count towards the forty."),
        box: works,

        # --- backgrounds and layers ---
        tiles: works("tiles of four colours each."),
        background: works("one background at a time, on a grid of 32×32 cells, scrolled and changed " \
                          "as on the Advance; a second background showing at once is refused. " \
                          "`rotate` and `scale` degrade to the background shown unturned, and " \
                          "`scroll_each_row` to the rows unbent."),
        canvas: works("its colours are four, as a background's tiles' are."),
        layers: works("a layer holds a background or sprites; a background in front of a sprite " \
                      "works. `transparency:` is refused: a Game Boy Color cannot show one layer " \
                      "through another."),
        layer: works("see `layers`."),

        # --- text ---
        draw_text: works("painted on a painted screen; on a tiled one each letter is a sprite, so " \
                         "they count towards the forty, ten to a row."),
        draw_number: works("see `draw_text`."),
        font: works,
        text_width: works,
        text_height: works,
        menu: works("see `draw_text` for what its rows are made of."),

        # --- numbers and logic ---
        var: works("a variable is the same 32-bit whole number as on the Advance."),
        save_var: works("kept in the cartridge's battery-backed memory."),
        save_data: works("kept in the cartridge's battery-backed memory."),
        saves_keep_everything: works,
        set: works, set!: works, add: works, add!: works, add_var: works, add_var!: works,
        sub: works, sub!: works, sub_var: works, sub_var!: works, copy: works, copy!: works,
        negate: works, negate!: works, flip: works, flip!: works, abs: works, abs!: works,
        negate_abs: works, negate_abs!: works, clamp: works, clamp!: works,
        approach: works, approach!: works,
        list: works,
        if_eq: works, if_ne: works, if_gt: works, if_lt: works, if_ge: works, if_le: works,
        if_gte: works, if_lte: works,
        func: works("`fast:` means nothing on a Game Boy Color, which runs all of its code alike."),
        call: works,
        scene: works("see `func` for `fast:`."),
        case_var: works,
        dump_func: degrades("a Game Boy Color build has no ARM to list, so nothing is printed."),
        entry: refused("`entry` is raw ARM for the Advance's processor, which a Game Boy Color does " \
                       "not have."),

        # --- input ---
        held: works("the eight buttons a Game Boy Color has. `:l` and `:r` are refused: it has no " \
                    "shoulder buttons."),
        pressed: works("see `held`."),
        if_held: works("see `held`."),
        if_pressed: works("see `held`."),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works,
        define_sound: works,
        beep: works,
        noise: works,
        wave: works,
        stop_wave: works,
        song: works("on the square, wave and noise voices. A part played on a recording " \
                    "(`voice ..., plays:`) is refused: a Game Boy Color cannot play recorded sound."),
        play_song: works,
        stop_music: works,
        music_volume: works,
        fade_music_in: works,
        fade_music_out: works,
        songs: works("see `song` for recordings."),
        sound_effects: works("see `song` for recordings."),
        sample: refused("a Game Boy Color has no way to play recorded sound. Use `song`, `beep`, " \
                        "`wave` or `noise`."),
        instrument: refused("an instrument plays a recording, which a Game Boy Color cannot (see " \
                            "`sample`). Write the part for the square or wave voice.")
      })

      # The answer for +verb+, or nil for a verb nobody has decided yet.
      def self.answer(verb) = ANSWERS[verb.to_sym]
    end
  end
end

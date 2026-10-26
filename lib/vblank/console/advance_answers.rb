# frozen_string_literal: true

module VBlank
  module Console
    # WHAT EVERY VERB DOES ON A GAME BOY ADVANCE (Console::Answers says what an answer is).
    #
    # Every verb works: the verbs were written for the Advance first, and its hardware does all of
    # them. The table is written out all the same, so the Advance answers the same question every
    # console does, the build asks every console alike, and a verb added to the builder is decided
    # for the Advance as deliberately as for the others. What a verb does here is its group file's
    # to say (.claude/dsl/), so most answers say only that.
    module AdvanceAnswers
      extend Answers

      PAGE = ".claude/dsl/game-boy-advance.md"

      # What a verb with nothing more to say answers.
      PLAIN = "as its group file says."

      ANSWERS = Ractor.make_shareable({
        # --- building, the screen and settings ---
        screen: works, setting: works,
        screen_width: works("240 on a Game Boy Advance."),
        screen_height: works("160 on a Game Boy Advance."),
        wait_vblank: works, halt: works, debug_halt: works,
        game_loop: works, once_a_frame: works, frames_since_power_on: works, each_pass: works,
        every: works, after: works, repeat: works, timer: works,

        # --- drawing on a painted screen ---
        pixel: works, fill_rect: works, dma_fill_rect: works, draw_rect_at: works, draw_column_at: works,
        clear_screen: works, inside: works, grid: works, camera: works, keep_showing: works,

        # --- fades, tints and screen effects ---
        fade: works, tint: works, fade_in: works, fade_out: works, flash_screen: works, fade_level: works,
        shake_screen: works, pixelate: works, pixelate_in: works, pixelate_out: works, pixelate_size: works,
        spotlight: works, iris_in: works, iris_out: works, iris_shut?: works, pulse: works,
        camera_follows: works,

        # --- pictures and sprites ---
        image: works, color: works, rgb: works, rgb8: works, colors: works, recolor: works,
        colors_in_use: works, mirror: works, upside_down: works, blit: works, sprite: works,
        draw_in_order: works, hide_sprites: works, picture_groups: works, pool: works, box: works,

        # --- backgrounds and layers ---
        tiles: works, background: works, canvas: works, layers: works, layer: works,

        # --- text ---
        draw_text: works, draw_number: works, font: works, text_width: works, text_height: works,
        menu: works,

        # --- numbers and logic ---
        var: works, save_var: works, save_data: works, clock: works, saves_keep_everything: works,
        set: works, set!: works, add: works, add!: works, add_var: works, add_var!: works,
        sub: works, sub!: works, sub_var: works, sub_var!: works, copy: works, copy!: works,
        negate: works, negate!: works, flip: works, flip!: works, abs: works, abs!: works,
        negate_abs: works, negate_abs!: works, clamp: works, clamp!: works,
        approach: works, approach!: works,
        list: works,
        if_eq: works, if_ne: works, if_gt: works, if_lt: works, if_ge: works, if_le: works,
        if_gte: works, if_lte: works,
        func: works, call: works, scene: works, case_var: works,
        uses: works("a pack's verbs are verbs of the game's own, and each one has its answer here."),
        dump_func: works("it lists the ARM a routine was made into."),
        entry: works("raw ARM for the Advance's processor (`.claude/dsl/escape-hatch.md`)."),

        # --- input ---
        held: works("the ten buttons a Game Boy Advance has, the shoulder buttons `:l` and `:r` among them."),
        pressed: works("see `held`."), if_held: works("see `held`."), if_pressed: works("see `held`."),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works, define_sound: works, beep: works, noise: works, wave: works, stop_wave: works,
        song: works, play_song: works, stop_music: works, music_volume: works, fade_music_in: works,
        fade_music_out: works, songs: works, sound_effects: works, sample: works, instrument: works
      })

      # WHAT .claude/dsl/game-boy-advance.md SAYS: the answers with words of their own, then every
      # other verb by name.
      def self.reference
        said, plain = ANSWERS.keys.partition { |verb| answer(verb).words != PLAIN }
        # The plain ones by name, in lines of about a hundred characters.
        names = "#{plain.map { |verb| "`#{verb}`" }.join(', ')}.".gsub(/(.{1,96})(?:\s+|\z)/, "\\1\n").chomp
        <<~MARKDOWN
          # The Game Boy Advance — what every verb does there

          A game built for the Advance (`VBlank.game "NAME", consoles: %i[gba]`, then
          `vblank build`) has a 240×160 screen (`screen_width`, `screen_height`), ten buttons,
          four backgrounds, 128 sprites and lists of sixteen colours. Every verb works there: the
          verbs were written for the Advance first. The answers are decided in
          `Console::AdvanceAnswers`, as every console's are, and the Game Boy Color's are in
          `.claude/dsl/game-boy-color.md`.

          This file is `Console::AdvanceAnswers.reference` written out (`ruby tools/console_answers.rb`),
          and a test fails when the two differ.

          #{answer_lines(said).join("\n")}

          These work as their group files say:

          #{names}
        MARKDOWN
      end
    end
  end
end

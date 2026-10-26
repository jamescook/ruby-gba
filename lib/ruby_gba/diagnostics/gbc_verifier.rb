# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # THE READER OVER A RUNNING GAME BOY COLOR CARTRIDGE: what a playthrough hands a script, and
    # what a test reads a Color cartridge through.
    #
    # Most of what the Advance's reader answers holds on a Color as it stands: the picture and
    # every question about it, memory by address, the game's variables by name, the save memory,
    # the sound that came out, playing on, and leaving layers or voices out (the emulator names
    # the Color's own). What does not is anything read through how the ADVANCE's cartridge is
    # laid out — its sprite table, its 512 colours, its game loop's instructions, its mixer — and
    # each of those is answered here the Color's way or refused by name. A question answered with
    # the Advance's layout would come back as a number, and a wrong one.
    #
    # THE SOUND OF THE FIRST FEW FRAMES is the Color's speaker settling after power-on, which the
    # emulator plays as it is: a silent game has some sound energy there that dies away. Ask about
    # the game's own sound after the game has started.
    #
    # Verifier.for picks this reader for a Color cartridge, so nothing that plays a cartridge has
    # to ask which console it is for.
    class GBCVerifier < Verifier
      # A Color's colours (see Verifier#palette): eight lists of four for the backgrounds, then eight
      # for the sprites.
      PALETTE_GROUP = 4
      PALETTE_HALF = 32
      PALETTE_HALVES = { backgrounds: 0, sprites: PALETTE_HALF }.freeze

      # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter says them
      # (Reference#sprites): each row's +name+, +x+, +y+ and +picture+, back to front, where the game
      # put them. The Color's own table of forty eight-pixel pieces cannot say whose a piece is, so
      # this reads the list the runtime keeps of what it placed (GBC::Places#drawn_sprite_rows),
      # which the Color's checked run compares with the interpreter after every pass.
      #
      # A cartridge with no build record cannot say whose a sprite is, and says so.
      def sprites(name = nil)
        refuse_missing_build_record!("which of its sprites is which")
        ensure_rendered!
        @drawn ||= IR::Backends::SpriteNames.new(@rom.source_program)
        rows = @rom.built.drawn_sprite_rows(@drawn, method(:mem8))
        name ? @drawn.rows_named(rows, name) : rows
      end

      # HOW MANY TIMES ROUND THE GAME LOOP THE COLOR GOT: the passes it finished, as
      # {Verifier#passes} counts them. The Color's runtime keeps a count of its own, so this reads
      # that and costs nothing — +count_passes:+ is not needed. Nil for a program with no game loop.
      #
      # WHAT THE RUNTIME COUNTS is the times the game waited for the screen, which is the passes
      # only for a game loop that waits for it once, at its top — the way `game_loop` waits unless
      # it is told `frame_sync: :manual`. It is then one ahead: the first wait comes before the first
      # pass has run at all, so after the bodies of thirty passes the count says thirty-one, whether
      # the run stopped at the next wait or part way through the next body. A game that waits
      # anywhere else is refused the count, since the waits are then not the passes.
      def passes
        refuse_missing_build_record!("where it counts its passes")
        ensure_rendered!
        program = @rom.source_program
        loop_node = program.walk.find { |node| node.kind == :loop } # what `game_loop` makes
        return nil unless loop_node

        refuse_waits_not_passes! unless waits_only_at_loop_top?(program, loop_node)
        [var_at(@rom.built.waits_counted_at) - 1, 0].max
      end

      # A Color game plays no recordings — Console::ColorAnswers refuses them — so the Advance's
      # mixer of recordings is answered here as it is for an Advance game that plays none.
      def voices = []
      def sounding = []
      def sample_clock = nil
      def sound_drops = SoundDrops::Reading.unmeasured

      # What only the Advance's reader can say, refused by name.
      def registers(*) = refuse_advance_only!(:registers, "the processor's registers")
      def wave_rate(*) = refuse_advance_only!(:wave_rate, "the wave voice's pitch")
      def run_until(*, **) = refuse_advance_only!(:run_until, "where each routine starts")
      def pad_reads(*) = refuse_advance_only!(:pad_reads, "how many times the game read the buttons")

      private

      # The Color's runtime counts its own passes (see #passes), so there is nothing to watch.
      def watch_game_loop_passes! = nil

      # Is the one wait for the screen the game makes the one at the top of its game loop?
      def waits_only_at_loop_top?(program, loop_node)
        waits = program.walk.select { |node| node.kind == :wait_vblank }
        waits.size == 1 && loop_node.children.first.equal?(waits.first)
      end

      def refuse_waits_not_passes!
        raise ArgumentError, "This game waits for the screen in places of its own (`wait_vblank`, or " \
                             "`frame_sync: :manual`). A Game Boy Color counts the waits, not the passes of the " \
                             "game loop, so this cartridge cannot say its passes. Count them in a variable of " \
                             "the game's own, and read it with `var`."
      end

      def refuse_advance_only!(question, what)
        raise ArgumentError, "`#{question}` works only on a Game Boy Advance cartridge. It reads #{what}, and only " \
                             "the Advance's reader can. This is a Game Boy Color cartridge. Read its memory by " \
                             "address (`mem8`, `mem16`, `mem32`), its variables (`var`), its sprites (`sprites`) " \
                             "or its screen instead."
      end
    end
  end
end

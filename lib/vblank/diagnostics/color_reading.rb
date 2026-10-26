# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING GAME BOY COLOR CARTRIDGE CAN BE ASKED that only the Color's way
    # of keeping things answers: whose each sprite is, and how many passes of the game loop it
    # finished — the same questions an Advance reader answers its own way (AdvanceReading).
    #
    # The Verifier is the one reader for every console, and a reader over a Color cartridge is
    # given these when it is made (Console::Kit#reading). What only the Advance's cartridge keeps —
    # the processor's registers, the wave voice's pitch, where each routine starts, how often the
    # game read the buttons, the mixer of recordings a Color game cannot have — a Color reader
    # does not have at all.
    #
    # THE SOUND OF THE FIRST FEW FRAMES is the Color's speaker settling after power-on, which the
    # emulator plays as it is: a silent game has some sound energy there that dies away. Ask about
    # the game's own sound after the game has started.
    module ColorReading
      # A Color's colours (see Verifier#palette): eight lists of four for the backgrounds, then eight
      # for the sprites.
      PALETTE = Verifier::PaletteLayout.new(half: 32, group: 4)

      # A GAME BOY CARTRIDGE WITH A CLOCK CHIP has the emulator write the chip's counters, and the
      # moment it last read them, after the save memory in its file: 48 bytes, the layout other Game
      # Boy emulators write too. What the game saved is the memory before them, in whole banks.
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: Console::GBCHardware::SRAM_BANK_SIZE, clock_bytes: 48)

      # HOW MANY TIMES ROUND THE GAME LOOP THE COLOR GOT: the passes it finished (see Verifier for
      # what a pass is). The Color's runtime keeps a count of its own, so this reads that and costs
      # nothing — +count_passes:+ is not needed. Nil for a program with no game loop.
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

      # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter says them
      # (Reference#sprites): a DrawnSprite for each, with its +name+, +x+, +y+ and +picture+, back
      # to front, where the game put them. Name one and only that sprite's rows come back. The
      # Color's own table of forty eight-pixel pieces cannot say whose a piece is, so this reads the
      # list the runtime keeps of what it placed (GBC::Places#drawn_sprite_rows), which the Color's
      # checked run compares with the interpreter after every pass.
      #
      # A cartridge with no build record cannot say whose a sprite is, and says so.
      #
      # @param name [Symbol, nil] keep only this declared sprite's rows; nil for every row
      # @return [Array<DrawnSprite>]
      def sprites(name = nil)
        refuse_missing_build_record!("which of its sprites is which")
        ensure_rendered!
        @drawn ||= IR::Backends::SpriteNames.new(@rom.source_program)
        rows = @rom.built.drawn_sprite_rows(@drawn, method(:mem8))
        name ? @drawn.rows_named(rows, name) : rows
      end

      private

      # The Color's runtime counts its own passes (see #passes), so there is nothing to watch.
      def watch_passes! = nil

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
    end
  end
end

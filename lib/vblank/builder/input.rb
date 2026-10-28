# frozen_string_literal: true

module VBlank
  class Builder
    # The input verbs: gate a block on a button — if_held / if_pressed — or turn a
    # button into a {Condition} — held / pressed — to branch with `.then` and
    # compose with `&` / `|`. Button names are validated against the shared IR
    # vocabulary. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    module Input
      # Run the block only while a button is held down.
      #
      # @param button [Symbol] :up, :down, :left, :right, :a, :b, :start, :select, :l, :r
      def if_held(button, &block)
        check_button!(button)
        push_container(Build.if_(Build.held(button))) do
          run_block(&block)
        end
      end

      # Run the block when a button is first pressed (edge-detected): down this
      # frame, up the previous one.
      #
      # @param button [Symbol] button name
      def if_pressed(button, &block)
        check_button!(button)
        push_container(Build.if_(Build.pressed(button))) do
          run_block(&block)
        end
      end

      # A {Condition} that holds while a button is down — branch on it with
      # `held(:up).then { ... }`.
      #
      # @param button [Symbol] button name
      def held(button)
        reject_block!(:held, button) if block_given?
        check_button!(button)
        DSL::Condition.new(self, Build.held(button))
      end

      # A {Condition} true on the frame a button is first pressed (edge-detected).
      #
      # @param button [Symbol] button name
      def pressed(button)
        reject_block!(:pressed, button) if block_given?
        check_button!(button)
        DSL::Condition.new(self, Build.pressed(button))
      end

      # SHAKE THE PLAYER'S HANDS for +frames+ frames, as a ball hitting a bumper does. +pattern+
      # says on which frames the motor runs, eight of them at a time and round again: a String of
      # eight, "#" for on and "." for off, read from the left. Steady by default; "#.#.#.#." is a
      # light buzz. A number is eight bits read as the Color's own games read theirs, so a pattern
      # taken from one of them plays the same (IR::Rumble).
      #
      #   rumble frames: 12
      #   rumble frames: 30, pattern: "##..##.."
      #
      # A rumble said while one runs takes its place, and `frames: 0` stops it. A rumble is
      # felt only on a console whose cartridge carries a motor (the Game Boy Color's); on any
      # other it does nothing, and the game plays the same.
      #
      # @param frames [Integer, DSL::Value] how many frames it lasts, 0 to 65535
      # @param pattern [String, Integer, DSL::Value] which of each eight frames the motor runs on
      def rumble(frames:, pattern: STEADY_RUMBLE)
        refuse_bad_rumble_frames!(frames)
        record(Build.rumble(frames: frames, pattern: rumble_bits!(pattern)))
      end

      # The motor on for every frame.
      STEADY_RUMBLE = 0xFF

      private

      # +pattern+ as the eight bits IR::Rumble reads; a friendly error for one that is not eight
      # frames.
      def rumble_bits!(pattern)
        return pattern unless pattern.is_a?(String) || pattern.is_a?(Integer)

        bits = pattern.is_a?(String) ? rumble_string_bits(pattern) : pattern
        return bits if bits.is_a?(Integer) && bits.between?(0, 0xFF)

        raise ArgumentError, "`rumble pattern: #{pattern.inspect}` is not 8 frames of the motor. Give a number " \
                             "from 0 to 255, or a String of 8 characters, \"#\" for on and \".\" for off."
      end

      def rumble_string_bits(pattern)
        return nil unless pattern.length == 8 && pattern.delete("#.").empty?

        IR::Rumble.bits_of(pattern.chars.map { |char| char == "#" })
      end

      def refuse_bad_rumble_frames!(frames)
        return unless frames.is_a?(Integer) && !frames.between?(0, IR::Rumble::MOST_FRAMES)

        raise ArgumentError, "`rumble frames: #{frames}` is not from 0 to #{IR::Rumble::MOST_FRAMES}. Give the " \
                             "number of frames the motor runs for, or 0 to stop it."
      end

      # Accept a known button name (from the shared IR vocabulary); raise a plain
      # error for anything else.
      def check_button!(button)
        return if IR::Buttons.readable?(button)

        raise ArgumentError, "#{button} is not a known button. Use one of these: :a :b :select :start :right :left :up :down :r :l."
      end

      # held/pressed hand back a Condition and take no block. A block here means a
      # dropped `.then` — the block would attach to held/pressed and be silently
      # ignored — so name the fix instead of losing the code.
      def reject_block!(verb, button)
        raise ArgumentError,
              "#{verb}(:#{button}) takes no block. To run code, write #{verb}(:#{button}).then { ... }. " \
              "Or use the block form: if_#{verb} :#{button} do ... end."
      end
    end
  end
end

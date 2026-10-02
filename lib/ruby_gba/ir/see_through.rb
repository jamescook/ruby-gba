# frozen_string_literal: true

module RubyGBA
  module IR
    # THE LAYERS A PROGRAM CAN BE SEEN THROUGH, and how an amount becomes a mix.
    #
    # A display blends a see-through layer with what is behind it as it draws, taking a
    # share of each: so much of the layer, so much of what is under it, added together
    # channel by channel. The shares come in STEPS, sixteen to a whole, and the two need
    # not add to a whole — past one, the mix is brighter than either side and a channel
    # stops at its brightest.
    #
    # Every backend reads the amounts through here, so the rounding from what the author
    # wrote (0 to 100) to steps is decided once.
    module SeeThrough
      module_function

      STEPS = 16

      # Every see-through layer the program declares, as SeeThroughLayer nodes.
      def layers(program)
        stack = program.walk.find { |node| node.kind == :layers }
        stack ? stack.see_through : []
      end

      # The one called +name+, or nil.
      def layer(program, name)
        layers(program).find { |node| node.name == name }
      end

      # The see-through layers +screenful+ (an IR::Stacking screenful) shows something of.
      # A screen can show one; a game can have one on each of its screens.
      def on_screen(screenful, layers)
        held = (screenful.scenery + screenful.objects).map(&:layer)
        layers.select { |layer| held.include?(layer.name) }
      end

      # The two shares, in steps, for a layer whose amounts are +shows+ and +behind+
      # (numbers, 0 to 100): [how much of the layer, how much of what is behind].
      #
      # The one-number form keeps the arithmetic it always had: what is behind is its
      # share rounded down, and the layer takes whatever is left of a whole. Two amounts
      # are each rounded to the nearest step, so 94 and 63 are the 15 and 10 a cartridge
      # that was drawn in steps says.
      def weights(layer, shows, behind)
        if layer.split
          far = floor_steps(behind)
          return [STEPS - far, far]
        end

        [nearest_steps(shows), nearest_steps(behind)]
      end

      # The same two shares for amounts the game works out, as one number: the layer's
      # share in the low byte and what is behind above it — the halfword a display with a
      # blend register of that shape is told. Only the two-amount form comes here; the
      # one-number form has a lowering of its own that predates this.
      def packed_shares_expr(layer)
        near = nearest_step_expr(layer.shows.copy)
        far = nearest_step_expr(layer.behind.copy)
        Build.binop(:|, near, Build.binop(:<<, far, Build.int(8)))
      end

      def nearest_step_expr(amount)
        scaled = Build.binop(:+, Build.binop(:*, amount, Build.int(STEPS)), Build.int(50))
        Build.clamped(Build.binop(:/, scaled, Build.int(100)), Build.int(0), Build.int(STEPS))
      end

      def floor_steps(percent) = ((percent * STEPS) / 100).clamp(0, STEPS)

      def nearest_steps(percent) = (((percent * STEPS) + 50) / 100).clamp(0, STEPS)
    end
  end
end

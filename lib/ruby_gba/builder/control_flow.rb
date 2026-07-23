# frozen_string_literal: true

module RubyGBA
  class Builder
    # The control-flow verbs: the game loop and timed triggers (game_loop,
    # wait_vblank, repeat, every, after), stopping (halt, debug_halt), and the
    # low-level comparison verbs (if_eq/if_ne/…). A concern of {Builder}, mixed in
    # so these stay flat DSL verbs.
    #
    # The `.then`/`.else` hooks the Condition/Branch handles call back into
    # (record_conditional, record_else) are the builder's public seam and live in
    # the core, not here — these are just the verbs.
    module ControlFlow
      # Stop execution (branch to self). Use after drawing static scenes.
      def halt
        record(Build.halt)
      end

      # Debug breakpoint: stop building here, so everything after this call is
      # ignored. Use it to bisect rendering issues — everything before debug_halt
      # runs, everything after never makes it into the ROM. Prints a warning so you
      # remember to remove it.
      #
      # @example Bisecting a black screen
      #   screen :bitmap
      #   clear_screen :red      # does this show up?
      #   debug_halt              # ← ROM stops here
      #   draw_text "HELLO"      # ← never recorded
      #   game_loop { ... }      # ← never recorded
      def debug_halt
        warn "[ruby-gba] debug_halt — ROM truncated here. Remove debug_halt when done."
        record(Build.halt) # the lowered ROM stops (branches to self) at this point
        @debug_halted = true
        throw :debug_halt
      end

      # True if debug_halt was called (used by RubyGBA.build to skip finalization steps).
      def debug_halted?
        @debug_halted
      end

      # Wait for the vertical blank — the safe moment to change what's on screen.
      def wait_vblank
        record(Build.wait_vblank)
      end

      # Wrap a block of code in an infinite loop. The block's statements become the
      # loop body in the IR tree; the backend adds the jump back to the top.
      #
      # @example
      #   game_loop do
      #     wait_vblank
      #     # ... game logic ...
      #   end
      def game_loop(&block)
        push_container(Build.loop_) do
          instance_eval(&block)
        end
      end

      # Run a block a set number of times, counting at run time. The block is given
      # a Value for the current index (0 up to count-1), so it can drive positions,
      # array access, and the like:
      #
      #   repeat(8) { |i| dma_fill_rect 119, i * 20 + 2, 2, 12, :gray }
      #
      # This is the run-time counterpart to Ruby's `8.times { |i| ... }`. Reach for
      # `times` when the count is known as you write the program (it's baked in);
      # reach for `repeat` when the count is decided while the game runs (a Value,
      # a variable — e.g. how many segments the snake has right now).
      #
      # @param count [Value, Integer, Symbol] how many times to run the block
      def repeat(count, &block)
        raise ArgumentError, "repeat needs a block: repeat(n) { |i| ... }" unless block

        @repeat_seq += 1
        index = :"__repeat_#{@repeat_seq}"
        ensure_var(index)
        ensure_var(count)
        i = Value.new(self, Build.var_ref(index), name: index)
        push_container(Build.repeat(Value.node_for(count), index)) do
          instance_exec(i, &block)
        end
      end

      # The console refreshes the screen ~59.73 times a second; like every game, we
      # count that as a round 60 frames per second. It's what lets a timer be given
      # in seconds — the unit a person actually thinks in — and turned into frames.
      FRAMES_PER_SECOND = 60

      # Run the block on a repeating beat — a blinking prompt, a spawn wave, a
      # repeating sound. Like {#repeat}, the counter behind it is hidden and managed
      # for you, so there's nothing to declare or reset. Call it once inside your game
      # loop, where each pass through the loop is one frame.
      #
      # The interval is +n+ frames, or +n+ seconds when you'd rather think in time —
      # the framework converts seconds to frames for you:
      #
      #   every(30) { blink.set 1 }              # every 30 frames
      #   every(0.5, :seconds) { blink.set 1 }   # the same, said in seconds
      #
      # @param n [Integer, Numeric] the interval (frames must be whole; seconds may be fractional)
      # @param unit [Symbol] :frames (default) or :seconds
      def every(n, unit = :frames, &block)
        counter = timer_counter!(:every, n, unit, block)
        frames = to_frames(n, unit)
        record(Build.add(counter, 1))
        reached = Build.binop(:>=, Build.var_ref(counter), Build.int(frames))
        gate = Build.if_(reached)
        # A cost hint for the estimator: this body only runs one frame in `frames`,
        # so it contributes 1/frames to the steady per-frame cost. Inert everywhere
        # else — the backends read the `if`, not this tag.
        gate[:cost_tag] = { kind: :every, period: frames }
        push_container(gate) do
          record(Build.set(counter, Build.int(0))) # start the next interval over
          instance_eval(&block)
        end
      end

      # Run the block once, +n+ frames (or seconds) from now, then never again — a
      # one-shot delay: an attract-mode timeout, a "GO!" that clears itself, a
      # scripted beat. The hidden counter stops once it reaches the target, so the
      # block fires exactly once. Call it inside your game loop, where each pass is
      # one frame.
      #
      #   after(600) { state.set 1 }             # 600 frames in
      #   after(10, :seconds) { state.set 1 }    # the same, said in seconds
      #
      # @param n [Integer, Numeric] the delay (frames must be whole; seconds may be fractional)
      # @param unit [Symbol] :frames (default) or :seconds
      def after(n, unit = :frames, &block)
        counter = timer_counter!(:after, n, unit, block)
        frames = to_frames(n, unit)
        # Count up only until the counter reaches the target — so it never overflows
        # or fires twice — and run the block on the one frame it lands exactly on it.
        not_yet = Build.binop(:<, Build.var_ref(counter), Build.int(frames))
        push_container(Build.if_(not_yet)) do
          record(Build.add(counter, 1))
          reached = Build.binop(:==, Build.var_ref(counter), Build.int(frames))
          push_container(Build.if_(reached)) do
            instance_eval(&block)
          end
        end
      end

      # --- Low-level comparison verbs ---
      # Compare a variable against an immediate or another variable; the block runs
      # only when the condition is true. The expression DSL's `(a > b).then { }` is
      # the friendlier form — these are the asm-tier escape hatch.

      # Maps DSL condition → the IR comparison operator, for building the `if`
      # node's condition (a binop over the variable and the operand).
      COND_TO_OP = {
        eq: :==, ne: :!=, gt: :>, lt: :<, ge: :>=, le: :<=,
      }.freeze

      %i[eq ne gt lt ge le].each do |cond|
        # Define if_eq, if_ne, if_gt, if_lt, if_ge, if_le
        define_method(:"if_#{cond}") do |var_name, operand, &block|
          emit_conditional(cond, var_name, operand, &block)
        end

        # Define if_gte (alias for if_ge), if_lte (alias for if_le)
        case cond
        when :ge then define_method(:if_gte) { |v, o, &b| emit_conditional(:ge, v, o, &b) }
        when :le then define_method(:if_lte) { |v, o, &b| emit_conditional(:le, v, o, &b) }
        end
      end

      private

      # Record an `if` node comparing a variable against an operand, and gather the
      # block's statements into it.
      #
      # @param cond [Symbol] condition (:eq, :ne, :gt, :lt, :ge, :le)
      # @param var_name [Symbol] variable to compare
      # @param operand [Integer, Symbol] immediate value or variable name to compare against
      def emit_conditional(cond, var_name, operand, &block)
        condition = Build.binop(COND_TO_OP.fetch(cond), Build.var_ref(var_name), Value.node_for(operand))
        ensure_var(var_name)
        ensure_var(operand)

        push_container(Build.if_(condition)) do
          instance_eval(&block)
        end
      end

      # Validate a timer's interval, unit, and block, then allocate the hidden frame
      # counter it counts on. The counter is cleared at boot (console RAM isn't
      # reliably zero at power-on) so the first interval measures from frame zero.
      def timer_counter!(verb, n, unit, block)
        raise ArgumentError, "#{verb} needs a block: #{verb}(n) { ... }" unless block
        unless %i[frames seconds].include?(unit)
          raise ArgumentError, "#{verb}'s unit is :frames or :seconds, got #{unit.inspect}"
        end
        # Frames are whole; seconds may be fractional (half a second is fine), but
        # either way the interval must come out to at least one frame.
        valid = unit == :frames ? n.is_a?(Integer) : n.is_a?(Numeric)
        unless valid && n.positive? && to_frames(n, unit).positive?
          raise ArgumentError, "#{verb} needs a positive number of #{unit}, got #{n.inspect}"
        end

        @timer_seq += 1
        counter = :"__timer_#{@timer_seq}"
        ensure_var(counter)
        at_boot(Build.set(counter, Build.int(0)))
        counter
      end

      # A timer interval in whole frames. Frames pass through; seconds convert at the
      # console's frame rate and round to the nearest whole frame.
      def to_frames(n, unit)
        unit == :seconds ? (n * FRAMES_PER_SECOND).round : n
      end
    end
  end
end

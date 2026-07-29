# frozen_string_literal: true

module RubyGBA
  class Builder
    # The variable verbs: declare and mutate the game's RAM variables — set/var,
    # add, sub, negate/flip, copy, abs, negate_abs, clamp, approach — plus
    # introspection (var_address, variables). A concern of {Builder}, mixed in so
    # these stay flat DSL verbs.
    #
    # The allocation itself (ensure_var / var_address! / the @variables table) is
    # builder core, shared by every concern, so it stays in Builder; these verbs
    # just record the ops and lean on it.
    module Variables
      # Set a variable's value. If the variable hasn't been declared yet,
      # it's automatically allocated in IWRAM. Returns a {Value} handle for the
      # variable, so it can be compared and mutated with the expression DSL.
      #
      # @param name [Symbol] variable name
      # @param value [Integer] value to store
      # @return [Value] a handle to the variable
      def set(name, value)
        record(Build.set(name, Value.node_for(value)))
        ensure_var(name)
        Value.new(self, Build.var_ref(name), name: name)
      end

      # Declare a variable and give it a starting value. Unlike {#set} (a runtime
      # assignment that happens where you write it), a declaration's initial value is
      # applied once, at program start — so declaring a variable inside a scene or a loop
      # still initializes it a single time, not every time that code runs. That's what
      # lets a game object declare its own state (a score, a flag) in its setup even when
      # that setup lives inside a scene. Returns a {Value} handle for the variable.
      #
      # @param name [Symbol] variable name
      # @param value [Integer, Symbol, Value] the starting value
      # @return [Value] a handle to the variable
      def var(name, value)
        ensure_var(name)
        at_boot(Build.set(name, Value.node_for(value)))
        Value.new(self, Build.var_ref(name), name: name)
      end

      # Add to a variable: var += operand.
      # Operand can be an immediate (Integer) or another variable (Symbol).
      #
      # @param name [Symbol] variable name
      # @param operand [Integer, Symbol] value to add
      def add(name, operand)
        record(Build.add(name, Value.node_for(operand)))
        ensure_var(name)
        ensure_var(operand)
      end
      alias add_var add

      # Subtract from a variable: var -= operand.
      # Operand can be an immediate (Integer) or another variable (Symbol).
      #
      # @param name [Symbol] variable name
      # @param operand [Integer, Symbol] value to subtract
      def sub(name, operand)
        record(Build.sub(name, Value.node_for(operand)))
        ensure_var(name)
        ensure_var(operand)
      end
      alias sub_var sub

      # Flip a variable's sign: var = -var.
      # Useful for reversing direction vectors.
      def negate(name)
        record(Build.negate(name))
        ensure_var(name)
      end
      alias flip negate

      # Copy one variable's value into another: dest = src.
      #
      # @param dest [Symbol] destination variable
      # @param src [Symbol] source variable
      def copy(dest, src)
        record(Build.copy(dest, src))
        ensure_var(dest)
        ensure_var(src)
      end

      # Absolute value: var = |var|
      # If var < 0, negate it. Otherwise leave it.
      def abs(name)
        record(Build.abs(name))
        ensure_var(name)
      end

      # Make a variable negative: var = -|var|
      # If var > 0, negate it. Otherwise leave it.
      def negate_abs(name)
        record(Build.negate_abs(name))
        ensure_var(name)
      end

      # Clamp a variable to [min, max] range.
      #
      # @param name [Symbol] variable name
      # @param min_val [Integer] minimum value
      # @param max_val [Integer] maximum value
      def clamp(name, min_val, max_val)
        record(Build.clamp(name, min_val, max_val))
        ensure_var(name)
      end

      # Move a variable toward +target+ by at most +step+ each call, never
      # overshooting: once it's within +step+ of the target it lands exactly on it
      # and stays there. This is the "chase, capped to a top speed" move — a homing
      # enemy, a camera easing to the player, pong's paddle tracking the ball.
      #
      #   cpu_y.approach ball_y - PADDLE_H / 2, CPU_SPEED
      #
      # +target+ is where it's heading — a number, another variable, or an
      # expression Value. +step+ is the most it may move per call, a positive whole
      # number fixed as you write the program (like a top speed).
      #
      # @param name [Symbol] the variable to move
      # @param target [Integer, Symbol, Value] where it's heading
      # @param step [Integer] the most it may move per call (a positive constant)
      def approach(name, target, step)
        raise ArgumentError, "approach's step must be a whole number, got #{step.inspect}" unless step.is_a?(Integer)
        raise ArgumentError, "approach's step must be positive, got #{step}" unless step.positive?

        ensure_var(name)
        ensure_var(target)
        delta = next_approach_var
        ensure_var(delta)
        # How far there is to go, capped to a single step in either direction, then
        # applied — a branchless move that can't overshoot: when the target is
        # already within one step, the cap does nothing and it lands right on it.
        record(Build.set(delta, Build.binop(:-, Value.node_for(target), Build.var_ref(name))))
        record(Build.clamp(delta, -step, step))
        record(Build.add(name, Build.var_ref(delta)))
      end

      # Get the IWRAM address allocated for a variable.
      # Useful for debugging and testing.
      #
      # @param name [Symbol] variable name
      # @return [Integer] IWRAM address
      def var_address(name)
        var_address!(name)
      end

      # All declared variables with their IWRAM addresses.
      # @return [Hash{Symbol => Hash}]
      def variables
        @variables.dup
      end

      private

      # A fresh hidden variable to hold one approach call's capped delta. Named per
      # call site at build time, so an approach inside a loop reuses the one
      # variable every frame rather than allocating forever.
      def next_approach_var
        @approach_seq += 1
        :"__approach_#{@approach_seq}"
      end
    end
  end
end

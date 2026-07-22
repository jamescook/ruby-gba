# frozen_string_literal: true

module RubyGBA
  class Builder
    # The variable verbs: declare and mutate the game's RAM variables — set/var,
    # add, sub, negate/flip, copy, abs, negate_abs, clamp — plus introspection
    # (var_address, variables). A concern of {Builder}, mixed in so these stay flat
    # DSL verbs.
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

      # Explicit variable declaration — same as `set` but reads better
      # when you want to declare variables at the top of a build block.
      alias var set

      # Add to a variable: var += operand.
      # Operand can be an immediate (Integer) or another variable (Symbol).
      #
      # @param name [Symbol] variable name
      # @param operand [Integer, Symbol] value to add
      def add(name, operand)
        record(Build.add(name, Value.node_for(operand)))
        ensure_var(name)
        ensure_var(operand) if operand.is_a?(Symbol)
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
        ensure_var(operand) if operand.is_a?(Symbol)
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
    end
  end
end

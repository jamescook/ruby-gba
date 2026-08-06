# frozen_string_literal: true

module RubyGBA
  # A handle to a value in a build block: a variable, a literal, or an arithmetic
  # expression over them. `var :name, init` hands one back, and ordinary Ruby
  # operators build more of them:
  #
  #   center = cpu_y + PADDLE_H / 2   # a Value (an expression, no variable of its own)
  #   (ball_y > center).then { ... }  # a comparison makes a Condition
  #
  # A Value that names a variable can be mutated — set / add / sub / clamp /
  # approach — which records the matching statement into the program. An
  # expression Value has no variable behind it, so mutating one is a friendly
  # error.
  #
  # Each Value wraps an IR value node; comparisons and arithmetic just build
  # bigger nodes, so nothing is committed to the program until a Condition's
  # `.then` (or a mutator) runs.
  #
  # Deliberately no `<=>` / Comparable: those demand a build-time -1/0/1, but a
  # Value's magnitude isn't known until the ROM runs — which is exactly why the
  # comparison operators return a Condition (a runtime test), not a Ruby boolean.
  # Comparable would also redefine < > == to derive from `<=>` and hand back
  # plain booleans, reviving the `if (x > 5)` footgun that `.then` exists to stop.
  class Value
    Build = IR::Build

    # The one coercion boundary. Turns any value operand into an IR value node, so
    # nothing but a value node ever reaches the IR: a Value contributes its node,
    # and everything else goes through Build.wrap (an Integer becomes a literal, a
    # Symbol a variable reference, a value node passes through, and anything that
    # can't be a value raises a plain-language error). Every collision point — the
    # operators below and the builder's verbs — funnels through here, so a Value
    # and its `:symbol` are interchangeable everywhere a value is expected.
    def self.node_for(operand)
      operand.is_a?(Value) ? operand.node : Build.wrap(operand)
    end

    # @param builder [Builder] the build the mutators record into
    # @param node [IR::Node] the value node this handle stands for
    # @param name [Symbol, nil] the variable name, if this handle names one
    def initialize(builder, node, name: nil)
      @builder = builder
      @node = node
      @name = name
    end

    # The IR value node behind this handle (a var_ref, an int, or a binop).
    attr_reader :node

    # --- arithmetic: build a bigger expression Value ---

    def +(other)
      Value.new(@builder, Build.binop(:+, @node, node_of(other)))
    end

    def -(other)
      Value.new(@builder, Build.binop(:-, @node, node_of(other)))
    end

    def *(other)
      Value.new(@builder, Build.binop(:*, @node, node_of(other)))
    end

    # Integer division, truncated toward zero (so -7 / 2 is -3). On the console
    # this becomes a BIOS Div call — the CPU has no divide instruction.
    def /(other)
      Value.new(@builder, Build.binop(:/, @node, node_of(other)))
    end

    # Multiply two numbers that both hold a fraction, and get back a number holding
    # a fraction — where plain `*` would overflow and give a wrong answer.
    #
    # A variable holds whole numbers only, so a program that needs halves and
    # quarters keeps its numbers multiplied up by a fixed amount and remembers to
    # divide back at the end. `fraction_bits: 16` means "multiplied up by 2**16", so
    # 1.5 is stored as 98304. Adding and subtracting those works as it is. Times
    # does not: two multiplied-up numbers multiply out to a number multiplied up
    # twice, and that intermediate is usually far too big for a variable to hold —
    # 1.5 times 1.5 needs 6,442,450,944 on the way. Plain `*` loses the top of it
    # and the answer is nonsense.
    #
    #   speed = var :speed, (3 * 65536) / 2     # 1.5, with 16 fraction bits
    #   step  = speed.times_fraction(speed, fraction_bits: 16)   # 2.25, kept the same way
    #
    # Both sides must carry the SAME number of fraction bits, and so does the answer.
    #
    # Nothing checks that for you: you say the number of bits at each multiply, and
    # the framework has no idea which of your variables hold fractions. That is a
    # deliberate stopping point rather than an oversight. The alternative is for the
    # scale to travel WITH the value, so `a * b` does the right thing because the
    # compiler knows what a and b are and mixing scales is a build error — much
    # closer to what this framework promises, and much more machinery (a type on
    # every Value, inference through every operation, conversions at every boundary
    # where a fraction meets a pixel coordinate). It is worth designing from real
    # call sites that turned out annoying, not from first principles, and there are
    # none yet — this is the first thing that can even express the arithmetic.
    def times_fraction(other, fraction_bits:)
      Value.new(@builder, Build.mul_fix(@node, node_of(other), fraction_bits))
    end

    # --- comparisons: build a Condition ---

    def >(other)
      compare(:>, other)
    end

    def <(other)
      compare(:<, other)
    end

    def >=(other)
      compare(:>=, other)
    end

    def <=(other)
      compare(:<=, other)
    end

    def ==(other)
      compare(:==, other)
    end

    def !=(other)
      compare(:!=, other)
    end

    # --- mutation: record a statement (variable handles only) ---

    # Assign a new value: an Integer, another variable, or an expression Value.
    def set(value)
      mutate { @builder.set(@name, node_of(value)) }
    end

    # Add to the variable (an Integer or another Value).
    def add(amount)
      mutate { @builder.add(@name, node_of(amount)) }
    end

    # Subtract from the variable (an Integer or another Value).
    def sub(amount)
      mutate { @builder.sub(@name, node_of(amount)) }
    end

    # Keep the variable within [lo, hi] (build-time constants).
    def clamp(lo, hi)
      mutate { @builder.clamp(@name, lo, hi) }
    end

    # Move the variable toward +target+ by at most +step+ each call, never
    # overshooting — the chase-at-a-top-speed move (see Builder#approach).
    def approach(target, step)
      mutate { @builder.approach(@name, target, step) }
    end

    # Replace the variable with its absolute value.
    def abs
      mutate { @builder.abs(@name) }
    end

    # Force the variable negative: it becomes -|value|.
    def negate_abs
      mutate { @builder.negate_abs(@name) }
    end

    # Flip the variable's sign.
    def flip
      mutate { @builder.flip(@name) }
    end

    private

    def compare(op, other)
      Condition.new(@builder, Build.binop(op, @node, node_of(other)))
    end

    # Run a mutation, returning self so calls chain — but only for a handle that
    # names a variable. Mutating an expression has nowhere to store the result.
    def mutate
      unless @name
        raise ArgumentError,
              "only a variable can be changed (one from `var :name`), not an " \
              "expression — assign the expression to a variable first"
      end
      yield
      self
    end

    # The IR node for an operand — the shared coercion (see Value.node_for).
    def node_of(other)
      Value.node_for(other)
    end
  end
end

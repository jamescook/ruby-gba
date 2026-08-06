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
    # @param fraction_bits [Integer, nil] how many fraction bits it carries; nil for a
    #   plain whole number (see {Fraction} for what carrying a fraction means)
    def initialize(builder, node, name: nil, fraction_bits: nil)
      @builder = builder
      @node = node
      @name = name
      @fraction_bits = fraction_bits
    end

    # The IR value node behind this handle (a var_ref, an int, or a binop).
    attr_reader :node

    # How many fraction bits this value carries, or nil if it is a plain whole number.
    attr_reader :fraction_bits

    # Whether this value carries a fraction rather than being a plain whole number.
    def fraction?
      !@fraction_bits.nil?
    end

    # --- arithmetic: build a bigger expression Value ---

    def +(other)
      aligned(:+, other)
    end

    def -(other)
      aligned(:-, other)
    end

    # Multiply. A fraction times a plain COUNT is ordinary multiplication and keeps the
    # fraction — twice as fast is twice as fast. A fraction times another FRACTION is
    # the one that overflows on the way, so it becomes the full-width multiply
    # automatically; see {Fraction} for why that is the point of the whole thing.
    def *(other)
      bits = Fraction.bits_of(other)
      if fraction? && bits
        same_scale!(bits, "multiply")
        return scaled(Build.mul_fix(@node, node_at_scale(other, bits), bits), bits)
      end

      scaled(Build.binop(:*, @node, node_at_scale(other, bits)), @fraction_bits || bits)
    end

    # Integer division, truncated toward zero (so -7 / 2 is -3). On the console
    # this becomes a BIOS Div call — the CPU has no divide instruction.
    def /(other)
      if fraction? && Fraction.bits_of(other)
        raise ArgumentError,
              "you cannot divide a number that holds a fraction by another number " \
              "that holds a fraction. The answer needs more room on the way than a " \
              "variable has. Work the answers out as you build the program, put them " \
              "in a `table`, and look them up."
      end

      scaled(Build.binop(:/, @node, node_at_scale(other, Fraction.bits_of(other))), @fraction_bits)
    end

    # --- moving between a fraction and a whole number ---

    # This value as a whole number, dropping the fraction — rounding down, so -0.5
    # becomes -1. This is what a pixel coordinate or a table index wants. It costs one
    # instruction (see IR::Int32.shift_right), not the divide it replaces. A value that
    # is already a whole number is handed back unchanged.
    def to_i
      return self unless fraction?

      Value.new(@builder, Build.shift_right(@node, @fraction_bits))
    end

    # This whole number as one that can hold a fraction, so it can be added to or
    # compared with one. A value that already holds a fraction is handed back unchanged.
    def to_f
      return self if fraction?

      bits = Fraction::DEFAULT_BITS
      scaled(Build.binop(:*, @node, Build.int(1 << bits)), bits)
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

    # Assign a new value: a number, another variable, or an expression Value. A variable
    # that holds a fraction takes one, and a number written here is converted to match.
    def set(value)
      mutate { @builder.set(@name, align!(value, "assign")) }
    end

    # Add to the variable (a number or another Value).
    def add(amount)
      mutate { @builder.add(@name, align!(amount, "add")) }
    end

    # Subtract from the variable (a number or another Value).
    def sub(amount)
      mutate { @builder.sub(@name, align!(amount, "subtract")) }
    end

    # Keep the variable within [lo, hi].
    def clamp(lo, hi)
      mutate { @builder.clamp(@name, aligned_operand(lo, "compare"), aligned_operand(hi, "compare")) }
    end

    # Move the variable toward +target+ by at most +step+ each call, never
    # overshooting — the chase-at-a-top-speed move (see Builder#approach).
    def approach(target, step)
      mutate { @builder.approach(@name, aligned_operand(target, "compare"), aligned_operand(step, "add")) }
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
      Condition.new(@builder, Build.binop(op, @node, align!(other, describe_op(op))))
    end

    # An operation whose two sides must be at the SAME scale — adding, subtracting,
    # comparing. The result carries whatever scale they agreed on.
    def aligned(op, other)
      node = align!(other, describe_op(op))
      scaled(Build.binop(op, @node, node), @fraction_bits || Fraction.bits_of(other))
    end

    # The IR node for +other+, checked against this value's scale and converted where
    # that can be done for free. Raises a friendly build error when the two cannot be
    # lined up.
    #
    # A whole number WRITTEN IN THE PROGRAM is converted, because `speed + 1` plainly
    # means one faster. A number the game works out cannot be: there is no way to tell
    # whether a counter holding 3 means three, or three sixty-fourths.
    def align!(other, verb)
      bits = Fraction.bits_of(other)
      return node_at_scale(other, bits) if @fraction_bits == bits
      return Build.int(Fraction.scale(other, @fraction_bits)) if fraction? && Fraction.literal?(other)

      if !fraction? && other.is_a?(Float)
        raise ArgumentError,
              "this holds whole numbers, so it cannot #{verb} #{other}. To give it a " \
              "fraction, declare it with one — `var :name, #{other}` rather than " \
              "`var :name, #{other.to_i}`.#{at_dsl_line}"
      end
      return node_of(other) if !fraction? && Fraction.literal?(other)

      same_scale!(bits, verb) if fraction? && bits
      raise ArgumentError, mixed_kinds_message(other, verb)
    end

    # Like #align!, but a number written in the program comes back as a plain Integer
    # rather than a node — because the verbs behind these still want to look at it
    # (`approach` refuses a step of zero or less, and cannot ask that of a node).
    def aligned_operand(other, verb)
      return Fraction.scale(other, @fraction_bits) if fraction? && Fraction.literal?(other)
      return other if !fraction? && other.is_a?(Integer)

      align!(other, verb)
    end

    # The IR node for +other+, with a Float written into the program turned into a whole
    # number at +bits+ fraction bits. This is the one place a Float becomes a number.
    def node_at_scale(other, bits)
      return Build.int(Fraction.scale(other, bits)) if other.is_a?(Float) && bits

      node_of(other)
    end

    # Two values that both hold a fraction, but not the same amount of it. Nothing can
    # be done for free here, and doing nothing gives an answer wrong by a factor of
    # thousands.
    def same_scale!(bits, verb)
      return if bits == @fraction_bits

      raise ArgumentError,
            "you cannot #{verb} these two numbers. They both hold a fraction, but not " \
            "the same amount of one: #{@fraction_bits} bits against #{bits}. Make " \
            "them both the same, or turn one into a whole number with `.to_i` first." \
            "#{at_dsl_line}"
    end

    # One side holds a fraction and the other is a plain whole number the game works
    # out. Which one is which decides what to tell the author to do.
    def mixed_kinds_message(_other, verb)
      fraction_side, whole_side = fraction? ? %w[left right] : %w[right left]
      "you cannot #{verb} these two numbers. The #{fraction_side} one holds a " \
        "fraction and the #{whole_side} one is a whole number the game works out, so " \
        "there is no way to tell what the whole number counts. Use `.to_f` on the " \
        "whole number to give it a fraction, or `.to_i` on the other one to drop its " \
        "fraction.#{at_dsl_line}"
    end

    # How the operator reads in a sentence, for an error message.
    def describe_op(op)
      case op
      when :+ then "add"
      when :- then "subtract"
      when :* then "multiply"
      when :/ then "divide"
      else "compare"
      end
    end

    # Where in the game's own source this went wrong — the first line of the caller
    # that is not inside the framework. Without it an error like this points at
    # value.rb, which is no help at all.
    def at_dsl_line
      frame = caller.find { |line| !line.include?("/lib/ruby_gba/") }
      frame ? " (at #{frame[%r{[^/]+\.rb:\d+}] || frame})" : ""
    end

    # A new handle for +node+ carrying +bits+ fraction bits. An expression, so it never
    # names a variable.
    def scaled(node, bits)
      Value.new(@builder, node, fraction_bits: bits)
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

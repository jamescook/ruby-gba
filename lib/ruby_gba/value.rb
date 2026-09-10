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

    # THE NUMBER THIS OPERAND ALREADY HAS, or nil when the game works it out as it runs.
    # The sibling of #node_for, and the same idea: ask for the answer rather than for the
    # class, because "a number the author wrote" is not one Ruby type. A bare 5, a literal
    # already wrapped for the tree, and a handle standing for one are the same fact, and a
    # variable, an expression and a run-time handle are the other fact.
    #
    # Asking after the class instead gets the second group right and the first group wrong:
    # a literal that had already been wrapped answered "the game works it out" and took the
    # run-time path for nothing. The report and the reference call these two fixed and
    # worked out, so the code says fixed too.
    def self.fixed_number(operand)
      node = operand.is_a?(Value) ? operand.node : operand
      return node if node.is_a?(Integer)

      node.value if node.is_a?(IR::Node) && node.kind == :int
    end

    # @param builder [Builder] the build the mutators record into
    # @param node [IR::Node] the value node this handle stands for
    # @param name [Symbol, nil] the variable name, if this handle names one
    # @param fraction_bits [Integer, nil] how many fraction bits it carries; nil for a
    #   plain whole number (see {Fraction} for what carrying a fraction means)
    # +declaring+ is how to tell somebody to declare THIS kind of thing with a fraction,
    # given the number they wrote. A variable and a list say it differently, and the rules
    # for lining two scales up are otherwise the same — so the rules live here once and
    # only the advice changes.
    def initialize(builder, node, name: nil, fraction_bits: nil, declaring: nil, mixing: nil)
      @builder = builder
      @node = node
      @name = name
      @fraction_bits = fraction_bits
      @declaring = declaring
      @mixing = mixing
    end

    # The IR value node behind this handle (a var_ref, an int, or a binop).
    attr_reader :node

    # How many fraction bits this value carries, or nil if it is a plain whole number.
    attr_reader :fraction_bits

    # Whether this value carries a fraction rather than being a plain whole number.
    def fraction?
      !@fraction_bits.nil?
    end

    # The node for +other+ brought to this value's scale, or a friendly error saying why
    # it cannot be. Public because a LIST carries a scale the same way but is not a Value,
    # and one implementation of these rules is worth more than a convenient shape.
    def node_matching(other, verb)
      align!(other, verb)
    end

    # --- arithmetic: build a bigger expression Value ---

    def +(other)
      aligned(:+, other)
    end

    def -(other)
      aligned(:-, other)
    end

    # The same value the other way round: `-speed` is as far backwards as `speed` is
    # forwards. It keeps a fraction, since flipping a sign changes nothing about scale.
    def -@
      scaled(Build.neg(@node), @fraction_bits)
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

    # Division, truncated toward zero (so -7 / 2 is -3).
    #
    # Dividing by a plain COUNT is ordinary division and keeps the fraction — half the
    # speed is half the speed. Dividing by another FRACTION is the one that needs care,
    # for the mirror of the reason `*` does: two numbers multiplied up by the same amount
    # divide that amount straight back out, so the answer would come back a whole number.
    # The framework widens the numerator first to stop that, which is what {Build.div_fix}
    # is; see {Fraction}. An answer with no room left is held at the end of the range
    # rather than wrapped, so dividing by something very close to zero gives the biggest
    # number there is instead of a negative one.
    def /(other)
      bits = Fraction.bits_of(other)
      if fraction? && bits
        same_scale!(bits, "divide")
        return scaled(Build.div_fix(@node, node_at_scale(other, bits), bits), bits)
      end
      return whole_over_fraction(other, bits) if bits

      scaled(Build.binop(:/, @node, node_at_scale(other, bits)), @fraction_bits)
    end

    # A plain whole number divided by one that holds a fraction. The answer holds a
    # fraction — 160 over 2.5 is 64, and over 2.4 it is not a whole number at all — so
    # the numerator is widened twice over: once to give the answer its fraction, and once
    # to cancel the divisor's.
    def whole_over_fraction(other, bits)
      Value.new(@builder, Build.div_fix(@node, node_of(other), bits * 2), fraction_bits: bits)
    end

    # What is left over after dividing — Ruby's meaning, so `-1 % 64` is 63.
    #
    # This is how you wrap a value onto a range: an angle that stepped below zero comes
    # back near a full turn, a map coordinate off the left edge comes back against the
    # right one. Wrapping onto a range that is a power of two (64, 256, 512) costs one
    # instruction; any other range is a real division.
    def %(other)
      scaled(Build.binop(:%, @node, node_at_scale(other, Fraction.bits_of(other))), @fraction_bits)
    end

    # --- the bits themselves ---
    #
    # Anything a game reads from a real console is several numbers packed into one: a
    # map cell carries a tile number, two flip flags and a palette bank; a row of a
    # collision shape is one bit per pixel; a save file is flags all the way down. The
    # code that reads those is written in bit operations, not because somebody liked
    # them but because that is what the bits are — and dividing cannot stand in, since
    # a mask over two fields that are not next to each other has no arithmetic form at
    # all.
    #
    # `&` keeps the bits both sides have, `|` keeps the bits either side has, `^` keeps
    # the ones exactly one side has, and `~` turns every bit the other way (which is how
    # a flag is cleared: `flags & ~DOOR_OPEN`). `<<` and `>>` slide the bits along.
    #
    # A number written into the program may stand on the LEFT of `&`, `|` and `^`, which
    # Ruby arranges through #coerce. It may not on the left of a shift — Ruby insists on
    # a plain number to the right of one — and #to_int is what says so in plain words
    # when somebody writes `0x8000 >> col`.

    def &(other)
      bitwise(:&, other)
    end

    def |(other)
      bitwise(:|, other)
    end

    def ^(other)
      bitwise(:^, other)
    end

    # Slide the bits up, filling in with zeros. Going off the top end empties the
    # number; see IR::Int32 for what a count past the end of a number does.
    def <<(places)
      shift_count!(:<<, places)
      bitwise(:<<, places)
    end

    # Slide the bits down, filling in with the sign — so a negative number stays
    # negative, which is what both the chip and Ruby do. Pair it with a mask to pull a
    # field out of the middle of a packed number: `(cell >> 12) & 15`.
    def >>(places)
      shift_count!(:>>, places)
      bitwise(:>>, places)
    end

    # Every bit the other way round.
    def ~
      whole_numbers_only!(:~, nil)
      Value.new(@builder, Build.bit_not(@node))
    end

    # `.then` ON A NUMBER, which Ruby will happily answer and this DSL must not.
    #
    # Every Ruby object has `then` — it hands the object to the block and gives back
    # whatever the block returned — so `(flags & DOOR).then { open_it }` runs the block
    # while the program is being BUILT, and records `open_it` with no test around it.
    # The door then opens every frame, and nothing said a word. That is the same slip
    # the orphaned-Condition guardrail exists for, arriving by another route: a flag
    # test in C is written `if (flags & MASK)`, so this is the first thing a person
    # reaching for these operators writes.
    def then(*)
      raise ArgumentError,
            "`.then` branches on a test, and this is a number. A number is not a yes " \
            "or a no, so there is nothing here to branch on. Compare it first: " \
            "`((flags & 4) != 0).then { ... }`.#{at_dsl_line}"
    end

    # RUBY ASKED FOR A PLAIN NUMBER, and this is one the game works out.
    #
    # Ruby calls this when it wants a real Integer and was handed something else.
    # Without it the program stops with "no implicit conversion of RubyGBA::Value into
    # Integer", which names a class the author never wrote and says nothing about what
    # to do instead. The place it actually happens is a shift with the number on the
    # left: Ruby routes `& | ^` through #coerce and pointedly does not route `<<` and
    # `>>` that way, so the message names that case.
    def to_int
      raise ArgumentError,
            "Ruby needs a plain whole number here, and this one is worked out as the " \
            "game runs. This usually happens on the right of `<<` or `>>`, so " \
            "`1 << bit` and `0x8000 >> bit` do not work. Put the value on the left " \
            "instead — `(row >> bit) & 1` reads one bit, and `bit` can still be " \
            "worked out as the game runs.#{at_dsl_line}"
    end

    # Let a plain number stand on the LEFT of an operator: `160 / distance` is how a
    # person writes a wall height, and Ruby asks the value on the right how to make sense
    # of that. A number written here takes this value's own kind, so dividing by
    # something holding a fraction gives an answer holding one.
    def coerce(other)
      bits = other.is_a?(Float) ? (@fraction_bits || Fraction::DEFAULT_BITS) : nil
      literal = bits ? Fraction.scale(other, bits) : other
      [Value.new(@builder, Build.int(literal), fraction_bits: bits), self]
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

    # A bit operation. Both sides are plain whole numbers — no scale to line up, since
    # the answer is about the bits and not about what they add up to.
    def bitwise(op, other)
      whole_numbers_only!(op, other)
      Value.new(@builder, Build.binop(op, @node, node_of(other)))
    end

    # A COUNT WRITTEN INTO THE PROGRAM that moves every bit off the end. The number is
    # right there to read, so this is a mistake the build can see, and it is always a
    # mistake: the answer no longer depends on what was shifted, and somebody who
    # wanted nothing would have written nothing.
    #
    # A count the GAME works out is left alone. That one comes out of data and can land
    # anywhere, which is exactly why IR::Int32 pins what happens when it lands outside.
    def shift_count!(op, places)
      count = Value.fixed_number(places)
      return if count.nil? || IR::Int32.shifts_within_the_number?(count)

      advice =
        if count.negative?
          "A shift count cannot go below 0. To move the bits the other way, use " \
            "`#{op == :<< ? '>>' : '<<'}`."
        else
          "Write a count from 0 to 31."
        end
      raise ArgumentError,
            "`#{op} #{count}` moves every bit off the end of the number. A whole " \
            "number here has 32 bits. So the answer is the same whatever the number " \
            "holds. #{advice}#{at_dsl_line}"
    end

    # A number that HOLDS A FRACTION keeps that fraction in its own low bits, so a bit
    # operation on one changes the fraction rather than the number the author can see —
    # and nothing in the answer would say so. Refuse it and say which side is at fault.
    def whole_numbers_only!(op, other)
      return unless fraction? || Fraction.bits_of(other)

      side = fraction? ? "this number" : "the number on the right"
      raise ArgumentError,
            "`#{op}` works on whole numbers, and #{side} holds a fraction. A fraction " \
            "is kept in the low bits, so `#{op}` would change the fraction and not the " \
            "number you can see. Use `.to_i` first to drop the fraction.#{at_dsl_line}"
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
              "fraction, #{declaring_advice(other)}.#{at_dsl_line}"
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

    # How to declare this kind of thing so that it holds a fraction. A variable says it
    # with its starting value; anything else says so its own way.
    def declaring_advice(other)
      return @declaring.call(other) if @declaring

      "declare it with one — `var :name, #{other}` rather than `var :name, #{other.to_i}`"
    end

    # One side holds a fraction and the other is a plain whole number the game works
    # out. Which one is which decides what to tell the author to do.
    def mixed_kinds_message(_other, verb)
      return "#{@mixing.call(fraction?)}#{at_dsl_line}" if @mixing

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

# frozen_string_literal: true

module RubyGBA
  # WHAT A PLACE KEEPS — plain whole numbers, or numbers carrying a fraction — and the
  # rules for bringing another number onto the same footing before the two meet.
  #
  # Four things in this framework keep numbers: a variable, a list, a pool field, and an
  # expression built out of those. They agree on the rules and disagree only on how to
  # tell somebody what went wrong, because "declare it with a fraction" is a different
  # sentence for each. So the rules live here once, and each place brings its own two
  # sentences (+declaring+ and +mixing+).
  #
  # WHY THIS IS NOT A METHOD ON Value. It used to be, and the three places that are not
  # Values had to build a throwaway one to borrow it — `list.push x` constructed a Value
  # out of nothing just to reach these rules, then dropped it. That is wasteful in a
  # small way and misleading in a large one: an expression built and never used is
  # exactly the mistake the orphaned-expression guardrail looks for, so the framework's
  # own scratch was indistinguishable from an author's dropped `flags | MASK`. Asking a
  # scale directly leaves the guardrail with only real expressions to judge.
  class Scale
    Build = IR::Build

    # @param bits [Integer, nil] how many fraction bits this place keeps; nil for plain
    #   whole numbers (see {Fraction} for what carrying a fraction means)
    # @param declaring [Proc, nil] given the number somebody wrote, how to tell them to
    #   declare THIS kind of place with a fraction
    # @param mixing [Proc, nil] given whether this place holds a fraction, how to say
    #   that it and the other number are two different kinds
    def initialize(bits: nil, declaring: nil, mixing: nil)
      @bits = bits
      @declaring = declaring
      @mixing = mixing
    end

    attr_reader :bits

    # Whether this place carries a fraction rather than plain whole numbers.
    def fraction?
      !@bits.nil?
    end

    # The IR node for +other+, brought to this scale where that can be done for free, or
    # a friendly error saying why it cannot be.
    #
    # A whole number WRITTEN IN THE PROGRAM is converted, because `speed + 1` plainly
    # means one faster. A number the game works out cannot be: there is no way to tell
    # whether a counter holding 3 means three, or three sixty-fourths.
    def node_matching(other, verb)
      other_bits = Fraction.bits_of(other)
      return self.class.node_at(other, other_bits) if @bits == other_bits
      return Build.int(Fraction.scale(other, @bits)) if fraction? && Fraction.literal?(other)

      if !fraction? && other.is_a?(Float)
        raise ArgumentError,
              "this holds whole numbers, so it cannot #{verb} #{other}. To give it a " \
              "fraction, #{declaring_advice(other)}.#{at_dsl_line}"
      end
      return Value.node_for(other) if !fraction? && Fraction.literal?(other)

      same_scale!(other_bits, verb) if fraction? && other_bits
      raise ArgumentError, mixed_kinds_message(verb)
    end

    # Like #node_matching, but a number written in the program comes back as a plain
    # Integer rather than a node — because the verbs behind these still want to look at
    # it (`approach` refuses a step of zero or less, and cannot ask that of a node).
    def operand_matching(other, verb)
      return Fraction.scale(other, @bits) if fraction? && Fraction.literal?(other)
      return other if !fraction? && other.is_a?(Integer)

      node_matching(other, verb)
    end

    # Two numbers that both hold a fraction, but not the same amount of it. Nothing can
    # be done for free here, and doing nothing gives an answer wrong by a factor of
    # thousands.
    def same_scale!(other_bits, verb)
      return if other_bits == @bits

      raise ArgumentError,
            "you cannot #{verb} these two numbers. They both hold a fraction, but not " \
            "the same amount of one: #{@bits} bits against #{other_bits}. Make " \
            "them both the same, or turn one into a whole number with `.to_i` first." \
            "#{at_dsl_line}"
    end

    # The IR node for +other+, with a Float written into the program turned into a whole
    # number at +bits+ fraction bits. This is the one place a Float becomes a number.
    #
    # On the class because the bits wanted are not always this scale's own: multiplying
    # asks at the OTHER side's scale, which is the whole reason that operation works.
    def self.node_at(other, bits)
      return Build.int(Fraction.scale(other, bits)) if other.is_a?(Float) && bits

      Value.node_for(other)
    end

    # Where in the game's own source this went wrong.
    def at_dsl_line = AuthorSource.at_author_line

    private

    # How to declare this kind of place so that it holds a fraction. A variable says it
    # with its starting value; a list and a pool field say it their own way.
    def declaring_advice(other)
      return @declaring.call(other) if @declaring

      "declare it with one — `var :name, #{other}` rather than `var :name, #{other.to_i}`"
    end

    # One side holds a fraction and the other is a plain whole number the game works
    # out. Which one is which decides what to tell the author to do.
    def mixed_kinds_message(verb)
      return "#{@mixing.call(fraction?)}#{at_dsl_line}" if @mixing

      fraction_side, whole_side = fraction? ? %w[left right] : %w[right left]
      "you cannot #{verb} these two numbers. The #{fraction_side} one holds a " \
        "fraction and the #{whole_side} one is a whole number the game works out, so " \
        "there is no way to tell what the whole number counts. Use `.to_f` on the " \
        "whole number to give it a fraction, or `.to_i` on the other one to drop its " \
        "fraction.#{at_dsl_line}"
    end
  end
end

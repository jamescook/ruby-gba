# frozen_string_literal: true

module RubyGBA
  module IR
    # Is this number always even, always odd, or can it be either?
    #
    # Most numbers a game works out are unknowable until it runs — but not all of
    # them. A game that lays its world out on a grid writes `cell * 8`, and however
    # the game works `cell` out, eight times anything is even. Proving that lets a
    # backend emit ONE shape of code where it would otherwise emit both and pick at
    # run time, and lets the cost model price the shape that will actually run
    # instead of the dearer of the two.
    #
    # This lives in the IR because it is a fact about the PROGRAM, not about a
    # machine: the same proof holds whoever runs the tree. It survives a machine's
    # wrap-around too — a whole-number machine wraps at an even width, and adding,
    # subtracting or multiplying inside that width cannot change whether a number is
    # even.
    #
    # THE ONE RULE THAT MATTERS: an answer of nil means "either, as far as this can
    # tell", and every kind and operator not named below falls through to it. Saying
    # "even" about a number that can be odd is the mistake with real consequences —
    # a backend would emit the wrong code and the estimate would be under what the
    # game costs — so the default is silence, and a new kind of expression is unknown
    # until somebody proves otherwise here.
    module Parity
      # @return [:even, :odd, nil] nil when it can be either
      def self.of(value)
        case value
        when Integer then value.even? ? :even : :odd
        when Node then of_node(value)
        end
      end

      # True when +value+ is provably even. The question most callers actually ask,
      # and it reads better than comparing to a symbol at the call site.
      def self.even?(value) = of(value) == :even

      def self.of_node(node)
        case node.kind
        when :int then of(node.value)
        when :neg then of(node.operand) # away from zero or toward it, it is the same number of ones
        when :binop then of_binop(node)
        end
      end

      def self.of_binop(node)
        lhs = of(node.lhs)
        rhs = of(node.rhs)
        case node.op
        when :+, :- then sum_parity(lhs, rhs)
        when :* then product_parity(lhs, rhs)
        # What is left over after taking whole multiples of an even number out of an
        # even number is even. Every other pairing can land either way.
        when :% then :even if lhs == :even && rhs == :even
        end
      end

      # Adding or subtracting: two of a kind make an even number, a mismatched pair
      # makes an odd one. Both sides have to be known — an unknown one moves the
      # answer as much as it likes.
      def self.sum_parity(lhs, rhs)
        return unless lhs && rhs

        lhs == rhs ? :even : :odd
      end

      # Multiplying is the useful one, and the only rule here that can answer while
      # half the expression stays a mystery: an even number times ANYTHING is even,
      # because the two is still in there whatever it is multiplied by. That is what
      # proves `cell * 8` even without knowing a thing about `cell`.
      def self.product_parity(lhs, rhs)
        return :even if lhs == :even || rhs == :even

        :odd if lhs == :odd && rhs == :odd
      end

      private_class_method :of_node, :of_binop, :sum_parity, :product_parity
    end
  end
end

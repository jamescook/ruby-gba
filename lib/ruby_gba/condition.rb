# frozen_string_literal: true

module RubyGBA
  # The result of comparing two Values: a yes/no test the program branches on.
  # Branch with `.then` (and an optional `.else`). Combine tests with & (both)
  # and | (either) — Ruby's `&&`/`||` can't be overloaded, so the single-character
  # forms are the ones that build a combined Condition.
  #
  # Always branch with `.then`, never a native Ruby `if`. `if (x > 5)` looks
  # right, but a Condition is *truthy* to Ruby, so its body would emit
  # unconditionally at build time with the comparison silently ignored — no error,
  # just a ROM that always runs the branch.
  class Condition
    Build = IR::Build

    def initialize(builder, node)
      @builder = builder
      @node = node
    end

    # The IR value node for the test (a comparison binop).
    attr_reader :node

    # Both tests must hold. Parenthesize the operands — `&` binds tighter than the
    # comparisons: (a > b) & (c < d).
    def &(other)
      compose(:and, other)
    end

    # Either test may hold: (a > b) | (c < d).
    def |(other)
      compose(:or, other)
    end

    # Run the block's statements only when the condition holds. Records an `if`
    # node carrying the block, the same shape the low-level if_* verbs build, and
    # returns a {Branch} so an `.else { ... }` can chain onto it.
    def then(&block)
      unless block
        raise ArgumentError, "(cond).then needs a block: (x > 0).then { ... }"
      end

      if_node = @builder.record_conditional(@node, &block)
      Branch.new(@builder, if_node)
    end

    private

    # Build a combined Condition. Both sides must be Conditions — you compose
    # yes/no tests, not raw numbers (a bare number has no branch meaning here).
    def compose(op, other)
      unless other.is_a?(Condition)
        raise ArgumentError,
              "compose conditions with & and |, e.g. (a > b) & (c < d) — got #{other.class}"
      end

      Condition.new(@builder, Build.binop(op, @node, other.node))
    end
  end
end

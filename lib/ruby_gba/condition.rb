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

    # The library's own source directory. A Condition is created deep inside the
    # library (a comparison, a compose), so to point a diagnostic at the line the
    # *author* wrote, we skip frames under here and take the first one outside it.
    LIB_DIR = __dir__

    def initialize(builder, node)
      @builder = builder
      @node = node
      @source = self.class.author_source
      # Enter the builder's "pending" set on birth; #then / & / | take us back out
      # once we're used. Whatever never leaves was built and never branched on —
      # the fingerprint of a comparison dropped into a native `if`.
      builder.track_condition(self)
    end

    # The IR value node for the test (a comparison binop).
    attr_reader :node

    # Where the author built this Condition ("file.rb:line"), or nil if it can't be
    # pinned down — used to point the orphaned-Condition diagnostic at their code.
    attr_reader :source

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

      @builder.consume_condition(self)
      if_node = @builder.record_conditional(@node, &block)
      Branch.new(@builder, if_node)
    end

    private

    # Build a combined Condition. Both sides must be Conditions — you compose
    # yes/no tests, not raw numbers (a bare number has no branch meaning here).
    # Both operands are folded into the new one, so both are now used.
    def compose(op, other)
      unless other.is_a?(Condition)
        raise ArgumentError,
              "compose conditions with & and |, e.g. (a > b) & (c < d) — got #{other.class}"
      end

      @builder.consume_condition(self)
      @builder.consume_condition(other)
      Condition.new(@builder, Build.binop(op, @node, other.node))
    end

    # The first call-stack frame outside the library — the author's line — as
    # "path:line", or nil if every frame is internal.
    def self.author_source
      frame = caller_locations.find { |loc| !loc.path.start_with?(LIB_DIR) }
      "#{frame.path}:#{frame.lineno}" if frame
    end
  end
end

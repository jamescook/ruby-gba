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
    #
    # SAY HOW OFTEN THE BLOCK RUNS with `estimate:`, the same word a `list`, a `pool` and a
    # `repeat` take:
    #
    #   (hurt > 0).then(estimate: { usually: 0 }) { ... }        # not on a normal frame
    #   (tick == 0).then(estimate: { usually: 1, in: 60 }) { ... } # about once a second
    #
    # WHY IT IS WORTH SAYING. Unsaid, the block is counted on EVERY frame, because a test
    # the game works out is one the estimate cannot see through. That is the safe reading
    # and it is often badly wrong: a death animation, a screen that repaints when a number
    # changes, a routine that answers a rare event — all of them read as ordinary
    # every-frame work, and a report that says so sends you optimising the wrong thing.
    #
    # WHAT IT CHANGES, and it is not quite nothing. The program does exactly what it did:
    # the same statements in the same order, and the test is still made every frame. But
    # the framework chooses what to keep in the console's quick memory by what a frame
    # costs, so telling it that a block is rare can hand that memory to something that
    # really does run every frame. That is the point rather than a side effect — it is a
    # speed difference and never a difference in what the game DOES.
    #
    # AND THE WORST FRAME IS UNCHANGED. A frame where the block does run pays for it in
    # full, so `rom.explain`'s worst case counts it whole however rare you said it was.
    def then(estimate: nil, &block)
      unless block
        raise ArgumentError, "(cond).then needs a block: (x > 0).then { ... }"
      end

      @builder.consume_condition(self)
      usually, per = Condition.how_often(estimate)
      if_node = @builder.record_conditional(@node, runs: usually, per: per, &block)
      Branch.new(@builder, if_node)
    end

    # Read `estimate: { usually: N, in: M }` — the block runs about N times in every M
    # frames. `in:` left out means one frame, so `usually: 0` is "not on a normal frame"
    # and `usually: 1` is "every frame", which is what an unsaid condition already counts.
    def self.how_often(estimate)
      return [nil, nil] if estimate.nil?

      unless estimate.is_a?(Hash)
        raise ArgumentError,
              "`estimate:` takes a hint in braces, like `estimate: { usually: 0 }`."
      end

      unknown = estimate.keys - %i[usually in]
      unless unknown.empty?
        raise ArgumentError,
              "The estimate hint `#{unknown.first}:` is not known. It knows: usually, in."
      end

      runs = estimate.fetch(:usually) do
        raise ArgumentError, "`estimate:` needs `usually:`, like `estimate: { usually: 0 }`."
      end
      per = estimate.fetch(:in, 1)
      check_how_often(runs, per)
      [runs, per]
    end

    def self.check_how_often(runs, per)
      unless runs.is_a?(Integer) && runs >= 0
        raise ArgumentError,
              "`usually:` says how many frames in every `in:` run the block. " \
              "Give 0 or more. You gave #{runs.inspect}."
      end
      unless per.is_a?(Integer) && per >= 1
        raise ArgumentError,
              "`in:` says how many frames to count `usually:` out of. " \
              "Give 1 or more. You gave #{per.inspect}."
      end
      return unless runs > per

      raise ArgumentError,
            "`usually: #{runs}, in: #{per}` says the block runs more often than every frame. " \
            "A block cannot run #{runs} times in #{per}. Give `usually:` #{per} or less."
    end
    private_class_method :check_how_often

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

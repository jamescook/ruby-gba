# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHAT EACH NODE OF THE PROGRAM TURNED INTO — counted while the code is emitted,
        # which is the only moment anybody knows.
        #
        # The cost model's weights are measured on the emulator, one operation at a time, and
        # most of them turn out to be a whole number of instructions at one instruction's
        # price. That number is not really a measurement: it is a fact the lowering has
        # exactly and the calibration recovers approximately, so the same decision ends up
        # written twice — once here, where it is executed, and once there, where it is
        # guessed at. Said once, by the side that knows, there is no pair left to drift.
        #
        # INSTRUCTIONS ARE ATTRIBUTED EXCLUSIVELY. A statement is charged for what it emitted
        # on its own, never for what its nested statements and its operands emitted, so the
        # counts down a tree add up instead of counting the same instruction at every level
        # of it. That matches how the estimate prices: a `set` and the variable read inside
        # it are two separate charges. The weights reach the same split by hand — each one is
        # measured with an operand in front of it and then has that operand taken back out —
        # and here it falls out of where the code came from.
        #
        # JUMPS ARE COUNTED BESIDE THE INSTRUCTIONS, because a count on its own is not a
        # price. A count is static and a frame is dynamic: where a node's own code holds a
        # loop, the count sees the body once and the frame runs it many times; where it holds
        # a call, the count sees the handful of instructions that set the call up and none of
        # the routine; and where it holds a branch over an alternative, the frame runs one side
        # and the count has both. Straight-line code is exactly the case where what was
        # emitted is what runs, and a node that emitted no jump says so.
        #
        # KEYED BY IDENTITY, not by value. Two `add :score, 1` statements written in
        # different places are equal as trees — {IR::Node} compares by shape — and they are
        # not the same statement. A Hash comparing them by value would merge the two and
        # report one statement that cost twice as much.
        #
        # AND COUNTED PER USE, because the tree SHARES nodes. A `Value` handle held in a Ruby
        # variable and written into sixty-nine places is one node object in sixty-nine
        # positions of the tree — measured on examples/breakout.rb, which really does that
        # with one variable read. The lowering emits it at each of them and anything reading
        # the tree meets it at each of them, so a plain total would be sixty-nine times what
        # one use costs, charged sixty-nine times over. What is kept is the total and how
        # many places it came from; what is asked for is one use.
        class Attribution
          # Every ARM instruction is four bytes, which is what makes counting them the same
          # question as counting the bytes they came to.
          INSTRUCTION_BYTES = 4

          # What one node emitted, across every place in the tree it was lowered from.
          # +jumps+ is how many branches are among those instructions — see the note above on
          # why a jump changes what a count means — and +times+ is how many places there
          # were, so that what one of them came to can be asked for.
          Emitted = Data.define(:instructions, :jumps, :times) do
            def initialize(instructions:, jumps:, times: 1) = super

            # What ONE use of this node came to. The places a shared node is lowered from
            # emit the same code, so their mean is what each of them costs — and it is a
            # fraction rather than a whole number only where they genuinely differ.
            def each_use = times.zero? ? 0 : instructions.to_f / times

            # Whether what was emitted is what a frame runs: no loop to go round, no call
            # into code that was counted somewhere else, no alternative to skip. Asked of
            # every place it was lowered from at once, so one awkward place speaks for all.
            def straight? = jumps.zero?

            # Spans added and taken apart — one stretch of the emitted code against another.
            # Both are still one place, so how many places is not part of this arithmetic.
            def +(other) = with(instructions: instructions + other.instructions, jumps: jumps + other.jumps)
            def -(other) = with(instructions: instructions - other.instructions, jumps: jumps - other.jumps)

            # The same node, found lowered somewhere else as well. This is the one that adds
            # a place, and #each_use is what the pair is kept for.
            def and_another(other)
              with(instructions: instructions + other.instructions,
                   jumps: jumps + other.jumps, times: times + other.times)
            end
          end

          # Nothing emitted and nowhere yet — what a node's span is measured against, and what
          # a fresh accumulator for its nested nodes starts from.
          ZERO = Emitted.new(instructions: 0, jumps: 0)

          # What each node emitted, keyed by the node itself. Valid once a lowering pass has
          # run; a node the pass never reached is absent rather than zero, which is the
          # difference between "it emitted nothing" and "this build never saw it".
          attr_reader :emitted

          # +emit+ is the code buffer being written — this watches it rather than being told,
          # since where the bytes and the branches come from is its whole subject.
          def initialize(emit)
            @emit = emit
            @emitted = {}.compare_by_identity
            # One frame per node still being lowered, holding what its nested nodes have
            # claimed so far. The innermost is last.
            @nested = []
          end

          # Nothing counted so far belongs to this pass. Called at the top of one, so a
          # backend lowered twice reports the second run rather than the two added together.
          def reset
            @emitted.clear
            @nested.clear
          end

          # Lower +node+ (whatever the block does) and remember what it alone emitted.
          def around(node)
            was = mark
            @nested.push(ZERO)
            result = yield
            inner = @nested.pop
            whole = mark - was
            # Tell whoever contains me that all of this is spoken for.
            @nested[-1] += whole unless @nested.empty?
            mine = whole - inner
            had = @emitted[node]
            @emitted[node] = had ? had.and_another(mine) : mine
            result
          end

          private

          # Where the emit pass has got to, in the two things being counted. Subtracting one
          # of these from a later one is what a node emitted between them.
          def mark = Emitted.new(instructions: @emit.pos / INSTRUCTION_BYTES, jumps: @emit.branches)
        end
      end
    end
  end
end

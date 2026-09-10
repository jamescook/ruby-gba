# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The `|=` slip, and everything shaped like it. Setting a flag in C is written
        # `flags |= MASK`, and both ways a person carries that over are silent:
        #
        #   flags | MASK      # an expression nobody kept — the flag is never set
        #   flags |= MASK     # Ruby reads this as `flags = flags | MASK`, which rebinds
        #                     # the Ruby local to an expression. The game's variable is
        #                     # untouched, and the name still looks right afterwards.
        #
        # The same hole swallows `hp + 1` where `hp.add 1` was meant. Nothing is emitted,
        # nothing complains, and the game quietly does not do the thing.
        #
        # HOW IT IS FOUND, which is the interesting part. This check cannot walk the tree,
        # for the same reason the orphaned-Condition check cannot: an expression nobody
        # kept is by definition NOT in the tree, so there is nothing there to see. But it
        # needs no "consume" bookkeeping either, because the tree already records what was
        # used — a node written into another node has its parent wired back (see IR::Node),
        # so an expression that found a home has a parent and one that did not has none.
        # The builder hands over every expression it built; the unparented ones are the
        # orphans.
        #
        # That test only works because the framework does not build expressions of its
        # own. It used to: a list checking a value against what it holds constructed a
        # throwaway Value purely to borrow the scale-alignment rules, so `xs.push cx` left
        # an unparented expression behind and looked exactly like this mistake. The rules
        # live in {Scale} now, which a list and a pool field ask directly.
        #
        # It reports errors, not warnings. An expression built and dropped did nothing at
        # all, and there is no legitimate reason to write one — unlike a statement, it has
        # no effect to be had.
        class OrphanedExpression
          NAME = :orphaned_expression
          PLAIN_NAME = "a number worked out and thrown away"

          # @param expressions [Array<Value>] every expression Value the build made
          def initialize(expressions)
            @expressions = expressions
          end

          # One Finding per expression whose node never joined the tree. The program is
          # not consulted: an orphan is precisely what is missing from it.
          def detect(_program)
            @expressions.reject { |value| value.node.parent }.map { |value| self.class.finding(value) }
          end

          # The Value itself is what the finding blames — it carries the author's call
          # site, and there is no node in the tree to point at. Standalone so the message
          # is easy to assert.
          def self.finding(value)
            message =
              "You worked out a number and then did nothing with it. So the program is " \
              "unchanged and the work is thrown away. This usually means a change that " \
              "did not happen. `flags | 4` gives you a NEW number. It leaves `flags` as " \
              "it was. To change the variable, write `flags.set flags | 4`. Take care " \
              "with `flags |= 4` too. Ruby reads that as `flags = flags | 4`. So the " \
              "Ruby name moves to the new number, and the game's variable stays as it " \
              "was. The same is true of `hp + 1`, where `hp.add 1` changes the variable."
            Finding.new(check: NAME, severity: :error, message: message, node: value)
          end
        end
      end
    end
  end
end

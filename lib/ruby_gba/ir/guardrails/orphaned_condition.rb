# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The native-`if` slip. A comparison in this DSL is a Condition object, and
        # Ruby treats any object as true, so `if x > 5` runs its body every time
        # with the comparison silently ignored — no error, just a ROM that always
        # takes the branch. A black-screen-class footgun, and Ruby gives no hook to
        # intercept a plain `if` on a truthy object.
        #
        # So unlike the other checks, this one can't detect by walking the IR: an
        # unused Condition never records a node, so there's nothing in the tree to
        # see. Detection lives in the builder instead — a Condition joins a "pending"
        # set when built and leaves it when used, so the leftovers *are* the orphans
        # (see Builder#track_condition). This check is handed that leftover set and
        # turns each into a Finding; it ignores the program because its data is the
        # pending set, not the tree. That lets it run as an ordinary check in the
        # Validator's list, no special path.
        #
        # It reports errors, not warnings: a Condition built and never branched on
        # did nothing at all, and the only way that happens is the native-`if` slip
        # — there's no legitimate cause to weigh against.
        class OrphanedCondition
          NAME = :orphaned_condition

          # @param pending [Array<Condition>] the Conditions built but never used
          def initialize(pending)
            @pending = pending
          end

          # One Finding per leftover Condition. The program is irrelevant here — the
          # data is the pending set — so it's ignored.
          def detect(_program)
            @pending.map { |condition| self.class.finding(condition) }
          end

          # A Finding for a Condition built but never used to branch. The Condition
          # itself is what the finding blames: it carries the author's call site, and
          # there is no node to point at (an orphan records none — that's the whole
          # reason this check reads a pending set instead of the tree). Standalone so
          # the message is easy to assert.
          def self.finding(condition)
            message =
              "You built a comparison like `x > 5` here. But nothing uses it to branch. " \
              "This almost always means it went into a native Ruby `if`. In this DSL, a " \
              "comparison is a Condition object. Ruby treats that object as always true. So " \
              "the `if` body runs every time, and the comparison has no effect. To fix this, " \
              "branch with `.then`. Write `(x > 5).then { ... }`, not `if x > 5`."
            Finding.new(check: NAME, severity: :error, message: message, node: condition)
          end
        end
      end
    end
  end
end

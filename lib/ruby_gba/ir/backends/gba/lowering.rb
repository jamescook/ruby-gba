# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Lowers a node by its kind: two plain kind-keyed Hashes (values, statements)
        # rather than a case statement, so a kind's handler is data — registered once, in
        # GBA#initialize, where every kind and its owner sit in one place — instead of a
        # branch that only fires from inside one file. A collaborator that needs to
        # evaluate a value node (Collision's per-pixel test needs its sprites' x/y/pose
        # operands, which are themselves value nodes) depends on a Lowering instead of on
        # whichever file happens to own that node kind, so two collaborators can each
        # need the other's node kind without depending on each other directly.
        #
        # Two tables, not one class each — a value node and a statement node are
        # different contracts (a value handler leaves its answer in the accumulator; a
        # statement handler leaves nothing live) — but they share this wiring.
        class Lowering
          # +progress+ is what the build says it is doing; +emitted+ answers how many bytes
          # have been emitted so far, which is what this pass shows as it goes. There is no
          # count to work towards — nothing knows how many instructions a program comes to
          # until they are emitted — so the growing size is the honest thing to show. (The
          # default never runs: with the silent progress the block below is never called.)
          #
          # +attribution+ counts what each node turned into. Every node in the program passes
          # through the two methods below, and this is the only place that is true, so this is
          # where the counting has to happen. See {Attribution}.
          def initialize(attribution:, progress: Progress.silent, emitted: -> { 0 })
            @values = {}
            @statements = {}
            @progress = progress
            @emitted = emitted
            @attribution = attribution
            @mode = :direct  # the mode draws currently lower in (set per func)
            @draw_area = nil # x, y, w, h while inside a clipped area; nil otherwise
          end

          # Register value/statement handlers — kind => a callable taking (node). Safe to
          # call more than once (a later call adds to the table rather than replacing it),
          # since a handler that is itself a collaborator (Collision) isn't built until
          # after the table's first, bulk registration.
          def values(**handlers) = @values.merge!(handlers)
          def statements(**handlers) = @statements.merge!(handlers)

          # An explicit "this kind is collected during the definitions pass and emits
          # nothing at statement time" — a real table entry, not a hole a missing kind
          # would also leave, so the coverage lock can't mistake one for the other.
          NOTHING = ->(_node) {}

          def value(node)
            @attribution.around(node) { @values.fetch(node.kind) { unknown_value(node) }.call(node) }
          end

          # Every statement in the program is lowered through here, nested ones included, so
          # this is where the pass says it is still going. One report per STATEMENT, not per
          # instruction: an instruction is what a statement turns into, and a build that
          # reported on each would spend more time saying so than emitting.
          def statement(node)
            @progress.tick { "#{@emitted.call} bytes" }
            @attribution.around(node) { @statements.fetch(node.kind) { unknown_statement(node) }.call(node) }
          end

          # Every kind with a value/statement handler — read by the coverage test that
          # checks these tables against IR::Nodes.by_kind.
          def value_kinds = @values.keys
          def statement_kinds = @statements.keys

          # Which mode the draws inside +block+ lower in — :direct, :buffered, or :tiled.
          # Restored on the way out, so a nested call (a func called from within another
          # func's body) can't leak its mode past its own return.
          attr_reader :mode

          def in_mode(mode)
            was = @mode
            @mode = mode
            yield
          ensure
            @mode = was
          end

          # The screen area every shape below +block+ clips against — [x, y, w, h], or
          # nil for the whole screen. `inside` doesn't nest at the surface (a guardrail
          # error there), so this doesn't need to model a stack either.
          attr_reader :draw_area

          def inside(x, y, w, h)
            @draw_area = [x, y, w, h]
            yield
          ensure
            @draw_area = nil
          end

          private

          def unknown_value(node)
            raise LoweringError, "the GBA backend cannot evaluate #{node.kind.inspect}"
          end

          def unknown_statement(node)
            raise LoweringError, "the GBA backend cannot lower #{node.kind.inspect} yet"
          end
        end
      end
    end
  end
end

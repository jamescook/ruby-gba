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
          def initialize
            @values = {}
            @statements = {}
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

          def value(node) = @values.fetch(node.kind) { unknown_value(node) }.call(node)
          def statement(node) = @statements.fetch(node.kind) { unknown_statement(node) }.call(node)

          # Every kind with a value handler — read by the coverage test that checks this
          # table against IR::Nodes.by_kind.
          def value_kinds = @values.keys

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

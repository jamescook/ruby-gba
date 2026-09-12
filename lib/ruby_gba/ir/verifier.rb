# frozen_string_literal: true

module RubyGBA
  module IR
    # Raised when the IR itself is malformed — a ruby-gba bug, never a mistake the
    # game developer made. Distinct from Guardrails::ValidationError, which reports
    # a *developer's* footgun in friendly language. See {Verifier}.
    class InvariantError < StandardError; end

    # The IR verifier: a well-formedness pass that mechanically enforces the
    # value model — "every operand is a value node" — instead of trusting each
    # verb to remember it.
    #
    # The DSL has two worlds. Authoring a ROM runs the build block once on the
    # host; the ROM then runs later on the console. A *value* — a number the
    # program works with — may be either an author-time literal (folded to a
    # constant) or a run-time variable/expression, and the value model unifies
    # them: everything flows through Build.wrap into a value node, so a verb
    # accepts either interchangeably. But nothing *proved* a verb actually wrapped
    # its operands — a verb that dropped a raw Integer into a value slot would fail
    # silently, the whole class of bug where a run-time value handed to an
    # author-time-only slot renders garbage with no error.
    #
    # This pass proves it. {Fields} declares, per node kind, whether each field is
    # a *value slot* (must hold a value node — any timing) or a *structural slot*
    # (an author-time literal of a stated type: a name, a size, packed bytes, a
    # color). The verifier walks the tree and checks every field against its slot;
    # a mismatch means a verb built the node wrong, so it raises {InvariantError}
    # for us to fix — it is not a Guardrails::Finding, is never shown to a game
    # developer, and offers no fix.
    #
    # The author-time escape hatch is already in the model, not a special case: a
    # constant is a value node of kind +int+, folded once while authoring and
    # loaded with a single move at run time — so "everything is a value" never
    # means "everything recomputes." A constant simply is a value whose kind is
    # +int+, and it satisfies the invariant like any other.
    module Verifier
      module_function

      # What a structural slot may hold, as predicates over the raw operand. A
      # value slot is handled separately (it must be a value *node*); these are the
      # author-time literals. `nil` is allowed for any structural slot, so optional
      # fields (a bitmap's transparency, a beep's overrides, an if's else) need no
      # special marking.
      TYPES = {
        name:    ->(v) { v.is_a?(Symbol) },                    # a variable / asset / func name
        option:  ->(v) { v.is_a?(Symbol) },                    # an enum choice (:front, :quarter, :left)
        int:     ->(v) { v.is_a?(Integer) },                   # a size, count, fixed coord, literal
        text:    ->(v) { v.is_a?(String) },                    # a string / packed bytes
        color:   ->(v) { v.is_a?(Symbol) || v.is_a?(String) || v.is_a?(Integer) },
        mode:    ->(v) { v.is_a?(Symbol) || v.is_a?(Integer) }, # a screen-mode name or raw register value
        tone:    ->(v) { v.is_a?(Symbol) || v.is_a?(Integer) }, # a defined-sound name or raw frequency
        list:    ->(v) { v.is_a?(Array) },                     # a case dispatch table
        score:   ->(v) { v.is_a?(Array) && v.all?(Music::Part) }, # a song's parts, each resolved
        save:    ->(v) { v.is_a?(Array) && v.all?(SavedVar) },    # the variables that survive power-off
        branch:  ->(v) { v.is_a?(Node) && v.kind == :else },   # an if's else-branch node
        flag:    ->(v) { v == true || v == false },            # an on/off switch (e.g. double buffering)
      }.freeze

      # Verify a whole program tree. Returns the node on success; raises
      # {InvariantError} on the first problem.
      #
      # Two passes, and the order is the point. The first proves the verifier
      # *recognizes* every node — its kind has a {Fields} row — so a new primitive the
      # model hasn't been taught about is a hard, unambiguous error before any
      # other check can mask it. Only then does the second pass judge whether each
      # recognized node is well-formed. A node the verifier can't identify never
      # slips through as "fine"; it fails loudly, pointing at the missing row.
      def verify!(node)
        node.walk { |n| check_known(n) }
        node.walk { |n| check_node(n) }
        node
      end

      # -- pass 1: every kind must be in the model (the drift backstop) --

      def check_known(node)
        return if Fields.known?(node.kind)

        raise InvariantError,
              "unknown IR kind #{node.kind.inspect} — no IR::Fields row. If you added a new IR " \
              "primitive, give it a class in IR::Nodes; the verifier refuses " \
              "any node it hasn't been taught, so drift can't slip through silently."
      end

      # -- pass 2: every recognized node must be well-formed --

      def check_node(node)
        schema = Fields.of(node.kind) # present — pass 1 proved it
        node.attrs.each { |field, value| check_field(node, schema, field, value) }
        check_value_slots_present(node, schema)
        check_children_are_statements(node)
        node
      end

      # An operand present on the node must match its declared slot.
      def check_field(node, schema, field, value)
        type = schema.fetch(field) do
          raise InvariantError,
                "#{node.kind}.#{field} is not a declared field — add it to IR::Fields[:#{node.kind}] " \
                "(a verb set an operand the schema doesn't know about)"
        end

        return if valid?(type, value)

        raise InvariantError, mismatch_message(node, field, type, value)
      end

      # A value slot must actually be there — a verb that forgot to set it is as
      # broken as one that set it wrong.
      def check_value_slots_present(node, schema)
        schema.each do |field, type|
          next unless type == :value
          next if node.attrs.key?(field)

          raise InvariantError,
                "#{node.kind}.#{field} is missing — a value operand wasn't set (route it through Build.wrap)"
        end
      end

      # Statements nest as children; value nodes live in #attrs. A value node found
      # among the children means a verb wired an operand as a statement.
      def check_children_are_statements(node)
        node.children.each do |child|
          next if child.statement?

          raise InvariantError,
                "#{node.kind} holds a #{child.kind} (category #{child.category}) as a child — " \
                "only statements nest as children; a value operand belongs in #attrs"
        end
      end

      # -- predicates --

      # A value slot must hold a value node (any kind whose category is :value — an
      # int literal, a var_ref, a binop, ...); a structural slot must hold its
      # author-time literal, and may be nil when the field is optional.
      def valid?(type, value)
        return value.is_a?(Node) && value.value? if type == :value
        return true if value.nil?

        TYPES.fetch(type).call(value)
      end

      def mismatch_message(node, field, type, value)
        if type == :value
          "#{node.kind}.#{field} must be a value node, but holds #{value.inspect} — the verb built this " \
            "node without routing #{field} through Value.node_for / Build.wrap"
        elsif value.is_a?(Node)
          "#{node.kind}.#{field} must be an author-time #{type} (#{value.inspect} is a value node) — a run-time " \
            "value leaked into a structural slot"
        else
          "#{node.kind}.#{field} must be an author-time #{type}, but holds #{value.inspect}"
        end
      end
    end
  end
end

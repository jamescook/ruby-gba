# frozen_string_literal: true

module RubyGBA
  module IR
    # WHAT EACH KIND OF NODE CARRIES, read off the classes that declare it.
    #
    # Every kind is a class that says its own operands (see {Nodes}), so this is a view over
    # those declarations rather than a table kept beside them. It is here for the two callers
    # that hold a kind's NAME rather than one of its nodes — a coverage check, and the cost
    # model reading an op off a cost entry. Anything holding a node asks the node.
    module Fields
      module_function

      # Every kind's operands, by kind name.
      def by_kind
        @by_kind ||= Nodes.by_kind.transform_values(&:tags).freeze
      end

      # Whether this kind is one the model has been taught.
      def known?(kind)
        Nodes.by_kind.key?(kind)
      end

      # The operands of one kind, each mapped to what it must hold. Empty for a kind that
      # carries nothing, and empty for a name nobody declared.
      def of(kind)
        Nodes.by_kind.key?(kind) ? Nodes.by_kind.fetch(kind).tags : EMPTY
      end

      EMPTY = {}.freeze
    end
  end
end

# frozen_string_literal: true

module RubyGBA
  # The open `if` a `.then` just recorded, waiting for an optional `.else`. On its
  # own it does nothing; calling `.else { ... }` fills in the branch that runs
  # when the condition was false.
  class Branch
    def initialize(builder, if_node)
      @builder = builder
      @if_node = if_node
    end

    # Statements to run when the condition was false.
    def else(&block)
      unless block
        raise ArgumentError, "(cond).then { }.else needs a block: .else { ... }"
      end

      @builder.record_else(@if_node, &block)
      nil
    end
  end
end

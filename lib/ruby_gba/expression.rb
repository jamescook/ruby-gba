# frozen_string_literal: true

module RubyGBA
  # A handle to a value in a build block: a variable, a literal, or an arithmetic
  # expression over them. `var :name, init` hands one back, and ordinary Ruby
  # operators build more of them:
  #
  #   center = cpu_y + PADDLE_H / 2   # a Value (an expression, no variable of its own)
  #   (ball_y > center).then { ... }  # a comparison makes a Condition
  #
  # A Value that names a variable can be mutated — set / add / sub / clamp — which
  # records the matching statement into the program. An expression Value has no
  # variable behind it, so mutating one is a friendly error.
  #
  # Each Value wraps an IR value node; comparisons and arithmetic just build
  # bigger nodes, so nothing is committed to the program until a Condition's
  # `.then` (or a mutator) runs.
  class Value
    Build = IR::Build

    # @param builder [Builder] the build the mutators record into
    # @param node [IR::Node] the value node this handle stands for
    # @param name [Symbol, nil] the variable name, if this handle names one
    def initialize(builder, node, name: nil)
      @builder = builder
      @node = node
      @name = name
    end

    # The IR value node behind this handle (a var_ref, an int, or a binop).
    attr_reader :node

    # --- arithmetic: build a bigger expression Value ---

    def +(other)
      Value.new(@builder, Build.binop(:+, @node, node_of(other)))
    end

    def -(other)
      Value.new(@builder, Build.binop(:-, @node, node_of(other)))
    end

    def *(other)
      Value.new(@builder, Build.binop(:*, @node, node_of(other)))
    end

    # --- comparisons: build a Condition ---

    def >(other)
      compare(:>, other)
    end

    def <(other)
      compare(:<, other)
    end

    def >=(other)
      compare(:>=, other)
    end

    def <=(other)
      compare(:<=, other)
    end

    def ==(other)
      compare(:==, other)
    end

    def !=(other)
      compare(:!=, other)
    end

    # --- mutation: record a statement (variable handles only) ---

    # Assign a new value: an Integer, another variable, or an expression Value.
    def set(value)
      mutate { @builder.set(@name, node_of(value)) }
    end

    # Add to the variable (an Integer or another Value).
    def add(amount)
      mutate { @builder.add(@name, node_of(amount)) }
    end

    # Subtract from the variable (an Integer or another Value).
    def sub(amount)
      mutate { @builder.sub(@name, node_of(amount)) }
    end

    # Keep the variable within [lo, hi] (build-time constants).
    def clamp(lo, hi)
      mutate { @builder.clamp(@name, lo, hi) }
    end

    # Replace the variable with its absolute value.
    def abs
      mutate { @builder.abs(@name) }
    end

    # Force the variable negative: it becomes -|value|.
    def negate_abs
      mutate { @builder.negate_abs(@name) }
    end

    # Flip the variable's sign.
    def flip
      mutate { @builder.flip(@name) }
    end

    private

    def compare(op, other)
      Condition.new(@builder, Build.binop(op, @node, node_of(other)))
    end

    # Run a mutation, returning self so calls chain — but only for a handle that
    # names a variable. Mutating an expression has nowhere to store the result.
    def mutate
      unless @name
        raise ArgumentError,
              "only a variable can be changed (one from `var :name`), not an " \
              "expression — assign the expression to a variable first"
      end
      yield
      self
    end

    # The IR node for an operand: another Value contributes its node; a bare
    # Integer/Symbol is wrapped into a literal / variable reference.
    def node_of(other)
      other.is_a?(Value) ? other.node : Build.wrap(other)
    end
  end

  # The result of comparing two Values: a yes/no test the program branches on.
  # Branch by calling `.then` with the block to run when the test holds.
  class Condition
    def initialize(builder, node)
      @builder = builder
      @node = node
    end

    # The IR value node for the test (a comparison binop).
    attr_reader :node

    # Run the block's statements only when the condition holds. Records an `if`
    # node carrying the block, the same shape the low-level if_* verbs build.
    def then(&block)
      @builder.record_conditional(@node, &block)
    end
  end
end

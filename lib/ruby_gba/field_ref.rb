# frozen_string_literal: true

module RubyGBA
  # A mutable handle to ONE field of ONE pool instance, at a run-time slot index —
  # what a pool's `each` hands you as `b.x`, `b.y`, and so on. It reads and writes that
  # instance's slot in the field's backing list, so it behaves like an ordinary variable
  # {Value} — arithmetic, comparisons, set/add/… — even though it lives at a computed
  # index rather than in a named variable. This front-end handle is the whole trick that
  # makes a pool read like game code: `b.y.add b.vy` is really `y[i] = y[i] + vy[i]`.
  class FieldRef < Value
    Build = IR::Build

    # @param builder [Builder] the build these operations record into
    # @param list_name [Symbol] the field's backing list (one list per field)
    # @param index_node [IR::Node] the value node for this instance's slot index
    def initialize(builder, list_name, index_node)
      @list_name = list_name
      @index_node = index_node
      # As a Value, this handle IS a read of the slot — so it composes in expressions
      # (b.x + 5, b.y > 100) exactly like a variable read. It carries no variable name,
      # so the mutators below override Value's (which write to a named variable).
      super(builder, read, name: nil)
    end

    # --- mutation: write back into this instance's slot ---

    def set(value)
      write(node_of(value))
    end

    def add(amount)
      write(Build.binop(:+, read, node_of(amount)))
    end

    def sub(amount)
      write(Build.binop(:-, read, node_of(amount)))
    end

    # The read-modify-write mutators have no single expression, so they round-trip
    # through a scratch variable: load the slot, apply the ordinary Value mutator, store
    # it back. This reuses Value's whole mutation vocabulary unchanged.
    def clamp(lo, hi)
      via_scratch { |s| s.clamp(lo, hi) }
    end

    def approach(target, step)
      via_scratch { |s| s.approach(target, step) }
    end

    def abs
      via_scratch(&:abs)
    end

    def negate_abs
      via_scratch(&:negate_abs)
    end

    def flip
      via_scratch(&:flip)
    end

    private

    # The value node that reads this instance's slot.
    def read
      Build.list_get(@list_name, @index_node)
    end

    # Store a value node into this instance's slot, returning self so calls chain.
    def write(value_node)
      @builder.record_statement(Build.list_set(@list_name, @index_node, value_node))
      self
    end

    # Load the slot into a reusable scratch variable, apply an ordinary Value mutation
    # to it, and store it back into the slot.
    def via_scratch
      scratch = @builder.field_scratch_var
      @builder.record_statement(Build.set(scratch, read))
      yield Value.new(@builder, Build.var_ref(scratch), name: scratch)
      write(Build.var_ref(scratch))
    end

    def node_of(other)
      Value.node_for(other)
    end
  end
end

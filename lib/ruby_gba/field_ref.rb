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
    # @param list [Symbol] the field's backing list (one list per field)
    # @param index [IR::Node] the value node for this instance's slot index
    # @param pool [Symbol] the pool this field belongs to, for its error messages
    # @param field [Symbol] the field's own name, likewise
    # @param fraction_bits [Integer, nil] what the field holds, from its declared default —
    #   a pool field written `vy: 0.0` carries a fraction the way a variable does
    def initialize(builder:, list:, index:, pool:, field:, fraction_bits: nil)
      @list_name = list
      @index_node = index
      @pool = pool
      @field = field
      # As a Value, this handle IS a read of the slot — so it composes in expressions
      # (b.x + 5, b.y > 100) exactly like a variable read. It carries no variable name,
      # so the mutators below override Value's (which write to a named variable).
      super(builder, read, name: nil, fraction_bits: fraction_bits,
                           declaring: self.class.declaring(pool, field),
                           mixing: self.class.mixing(pool, field))
    end

    # A handle, not a working-out: it stands for one slot of one field, so writing one
    # down and doing nothing with it is as harmless as naming a variable. See Value#handle?.
    def handle? = true

    # WHAT A POOL FIELD KEEPS, without building a handle to ask. A pool checks the values
    # a `spawn` was given against the fields they are going into, and it has no instance
    # to hold a handle for — nor any need of one. On the class so that a field's own two
    # sentences are written once and both callers say the same thing.
    def self.scale(pool:, field:, bits:)
      Scale.new(bits: bits, declaring: declaring(pool, field), mixing: mixing(pool, field))
    end

    # How to make THIS field hold a fraction: say so in the default it is declared with,
    # which is the same way a variable says it.
    def self.declaring(pool, field)
      lambda { |other|
        "declare the field with one — `pool :#{pool}, #{field}: #{other}` rather than " \
          "`#{field}: #{other.to_i}`"
      }
    end

    # ...and the other mismatch. A field has no left and right side, so the wording a
    # plain operator uses does not fit it.
    def self.mixing(pool, field)
      lambda { |field_holds_fraction|
        holds, given = if field_holds_fraction
                         ["numbers with a fraction", "a whole number the game works out"]
                       else
                         ["whole numbers", "a number with a fraction"]
                       end
        "`pool :#{pool}` keeps #{holds} in its #{field.inspect} field, and this is " \
          "#{given}. There is no way to tell what it counts. Use `.to_f` on the whole " \
          "number to give it a fraction, or `.to_i` on the other one to drop its fraction."
      }
    end

    # --- mutation: write back into this instance's slot ---

    def set(value)
      write(matched(value, "hold"))
    end

    def add(amount)
      write(Build.binop(:+, read, matched(amount, "add")))
    end

    def sub(amount)
      write(Build.binop(:-, read, matched(amount, "subtract")))
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
    # to it, and store it back into the slot. The scratch carries the field's scale, so a
    # `clamp` or an `approach` on a field that holds a fraction follows the same rules.
    def via_scratch
      scratch = @builder.field_scratch_var
      @builder.record_statement(Build.set(scratch, read))
      yield Value.new(@builder, Build.var_ref(scratch), name: scratch, fraction_bits: fraction_bits)
      write(Build.var_ref(scratch))
    end

    # A value on its way into the slot, checked against what the field holds.
    def matched(other, verb)
      node_matching(other, verb)
    end

    def node_of(other)
      Value.node_for(other)
    end
  end
end

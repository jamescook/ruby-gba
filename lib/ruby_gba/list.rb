# frozen_string_literal: true

module RubyGBA
  # A handle to a list in a build block: a bounded, ordered collection whose
  # length changes as the game runs — a snake's growing body, a queue of shots on
  # screen. `list :name, capacity: N` hands one back, and its methods read like
  # working with a Ruby array:
  #
  #   body = list :body, capacity: 256
  #   body.push head          # grow at the front of the queue
  #   body.shift              # drop the oldest
  #   head = body.last        # a Value — the newest cell
  #   body.each { |cell| draw_rect_at cell, 40, 2, 2, :green }
  #
  # A List is the collection peer of {Value}: where a Value stands for one number,
  # a List stands for a run of them. The two kinds of method mirror that split:
  #
  #   * The ones that *change* the list — push / pop / shift / []= — record a
  #     statement into the program at the current point (inside a loop, an `if`,
  #     wherever the call sits), just like the builder's other verbs. They return
  #     self so calls chain.
  #
  #   * The ones that *read* it — [] / length / first / last — hand back a {Value},
  #     so an element or the length flows straight into arithmetic, a comparison,
  #     or another draw. Nothing is committed to the program by a read alone.
  #
  # Values going in or coming out cross the one coercion boundary (Value.node_for):
  # an index or a pushed value may be a Value, a bare Integer, or a :symbol naming
  # a variable, and a read hands back a Value — so a list composes with the rest of
  # the expression DSL without the caller thinking about IR nodes.
  class List
    Build = IR::Build

    # A list can hold numbers that carry a FRACTION, the same as a variable can. It is
    # declared once, on the list — `list :speeds, capacity: 8, holds: 0.0` — and from then
    # on every value read out of it carries the scale and every value put in is checked
    # against it, so the game writes halves and quarters and never mentions the scale
    # again. Without it, many of something that needs a fraction — the positions of a
    # crowd, a speed per instance — means picking a scale and carrying it by hand, which
    # is the exact bookkeeping the fraction support exists to remove.
    #
    # @param builder [Builder] the build the operations record into
    # @param name [Symbol] the list's name (its handle in the program)
    # @param fraction_bits [Integer, nil] how much fraction its items carry, nil for whole
    def initialize(builder, name, fraction_bits: nil)
      @builder = builder
      @name = name
      @fraction_bits = fraction_bits
    end

    # The list's name.
    attr_reader :name

    # How much fraction this list's items carry, or nil if they are whole numbers.
    attr_reader :fraction_bits

    # --- growing / shrinking: record a statement ---

    # Add a value at the end of the list. Accepts a Value, an Integer, or a
    # :symbol naming a variable.
    def push(value)
      record(Build.list_push(@name, item_node(value, "hold")))
      self
    end
    alias << push

    # Drop the oldest item (the front of the list).
    def shift
      record(Build.list_drop(@name, from: :front))
      self
    end

    # Drop the newest item (the back of the list).
    def pop
      record(Build.list_drop(@name, from: :back))
      self
    end

    # Overwrite the item at `index`. The slot must already hold one (push first).
    def []=(index, value)
      record(Build.list_set(@name, Value.node_for(index), item_node(value, "hold")))
      value
    end

    # --- reading: hand back a Value ---

    # The item at `index`, as a Value. The index may be a Value, an Integer, or a
    # :symbol naming a variable.
    def [](index)
      item_value(Build.list_get(@name, Value.node_for(index)))
    end

    # How many items the list holds right now, as a Value. A COUNT, so it never carries a
    # fraction however much the items do — half an item is not a thing.
    def length
      value_at(Build.list_len(@name))
    end

    # The first item (index 0), as a Value.
    def first
      self[0]
    end

    # The last item (index length - 1), as a Value.
    def last
      self[length - 1]
    end

    # Run the block once for each item, front to back, handing it the item as a
    # Value. Sugar over {Builder#repeat}: the count is the list's current length,
    # so the loop tracks the list even as earlier iterations change it.
    def each(&block)
      list = self # `repeat` runs its block in the builder's context; keep our ref
      @builder.repeat(length) { |index| block.call(list[index]) }
    end

    private

    # Attach a list statement (push/drop/set) at the current build point.
    def record(node)
      @builder.record_statement(node)
    end

    # Wrap a list value node (get/length) in a Value handle so it composes with the
    # expression DSL.
    def value_at(node)
      Value.new(@builder, node)
    end

    # ...and the same for an ITEM, which carries whatever fraction the list holds.
    def item_value(node)
      Value.new(@builder, node, fraction_bits: @fraction_bits,
                                declaring: declaring, mixing: mixing)
    end

    # How to make THIS list hold fractions, for the error somebody gets when they put a
    # number with one into a list of whole numbers.
    def declaring
      @declaring ||= ->(other) { "add `holds: #{other}` where `list :#{@name}` is declared" }
    end

    # ...and how to say the other mismatch, where the number and the list are two kinds.
    # A list has no left and right side, so the wording a plain operator uses does not fit.
    def mixing
      @mixing ||= lambda { |list_holds_fraction|
        holds, given = if list_holds_fraction
                         ["numbers with a fraction", "a whole number the game works out"]
                       else
                         ["whole numbers", "a number with a fraction"]
                       end
        "`list :#{@name}` holds #{holds}, and this is #{given}. There is no way to tell " \
          "what it counts. Use `.to_f` on the whole number to give it a fraction, or " \
          "`.to_i` on the other one to drop its fraction."
      }
    end

    # A value on its way INTO the list, checked against what the list holds. The rules are
    # the ones a variable follows, and they live in {Scale} so there is one copy of them.
    def item_node(value, verb)
      item_scale.node_matching(value, verb)
    end

    # What this list keeps, as something that can answer the alignment questions on its
    # own. Asked directly rather than through a throwaway Value, so pushing onto a list
    # does not look like an expression somebody built and dropped.
    def item_scale
      @item_scale ||= Scale.new(bits: @fraction_bits, declaring: declaring, mixing: mixing)
    end
  end
end

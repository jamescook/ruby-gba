# frozen_string_literal: true

module RubyGBA
  # A rectangle in screen space — a top-left corner (x, y) and a size (w, h). It
  # describes a region for collision tests like {Builder#overlaps?}; it draws
  # nothing itself. Each coordinate can be a fixed number, a :variable, or an
  # expression {Value}, so one box can describe a moving thing (a ball whose x/y are
  # variables) as naturally as a fixed wall. Its edges read back as Values —
  # `right` is `x + w`, `bottom` is `y + h` — so a test composes with the same
  # expression sugar as everything else. Make one with the `box` verb.
  class Box
    include Bounds # gains overlaps? from x / y / right / bottom

    attr_reader :x, :y, :w, :h

    # @param builder [Builder] the build its coordinates belong to
    # @param x, y, w, h [Integer, Symbol, Value] corner and size, each an operand
    #   the expression DSL understands
    def initialize(builder, x, y, w, h)
      @x = coerce(builder, x)
      @y = coerce(builder, y)
      @w = coerce(builder, w)
      @h = coerce(builder, h)
    end

    # The right edge (x + w), as an expression Value.
    def right
      @x + @w
    end

    # The bottom edge (y + h), as an expression Value.
    def bottom
      @y + @h
    end

    private

    # Wrap any operand — a number, a :variable, or an expression Value — as a Value,
    # so every field of a box speaks the expression DSL regardless of how it came in.
    def coerce(builder, operand)
      Value.new(builder, Value.node_for(operand))
    end
  end
end

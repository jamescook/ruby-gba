# frozen_string_literal: true

module RubyGBA
  # A read-only ROM table declared with `table`. Index it with `[]` to read an
  # element at run time as a {Value}; its size is fixed at build time. Reads compose
  # with the expression DSL, so `sin[angle]` drops straight into `y.set sin[angle]`.
  class Table
    Build = IR::Build

    # @param builder [Builder] the build reads record into
    # @param name [Symbol] the table's name
    # @param count [Integer] how many elements it holds
    # @param fraction_bits [Integer, nil] fraction bits its values carry, if any
    def initialize(builder, name, count, fraction_bits: nil)
      @builder = builder
      @name = name
      @count = count
      @fraction_bits = fraction_bits
    end

    attr_reader :name

    # The element at +index+, as a {Value}. +index+ may be a Value, an Integer, or a
    # :symbol naming a variable. An out-of-range index is made safe by the read: a
    # power-of-two table wraps it, any other size clamps it to the ends.
    #
    # A table written with Floats hands back values that hold a fraction, so a sine
    # table reads as a sine and the scale never has to be mentioned again.
    def [](index)
      Value.new(@builder, Build.table_get(@name, Value.node_for(index)), fraction_bits: @fraction_bits)
    end

    # How many elements the table holds — a build-time constant (a plain Integer,
    # since the size is fixed when the program is built).
    def length
      @count
    end
  end
end

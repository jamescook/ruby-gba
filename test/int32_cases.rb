# frozen_string_literal: true

# THE CALCULATIONS A RUNTIME'S ARITHMETIC IS HELD TO, for a lowering whose runtime is written
# again in another language (the JavaScript one's rg_int32.js, the Ruby one's rg_int32.rb): the
# values where a number of that language and a 32-bit whole number are most likely to part ways —
# the ends of the range, either side of nought, powers of two, shift counts on and past the edge,
# products and fractions too big to hold exactly — every pair of them, plus a spread of random
# ones. IR::Int32 is the answer key. The helpers it has no function for (a comparison, joining two
# conditions, a narrow list slot) are answered the way the interpreter answers them.
module Int32Cases
  Int32 = VBlank::IR::Int32
  ListValue = VBlank::IR::Backends::Reference::ListValue

  EDGES = [
    0, 1, -1, 2, -2, 3, -7, 7, 64, -64, 127, 128, -128, -129, 255, 256,
    0x7FFF, 0x8000, -0x8000, 0xFFFF, 0x1_0000, -0x1_0000, 98_304, -98_304,
    1 << 30, -(1 << 30), Int32::MAX, Int32::MAX - 1, Int32::MIN, Int32::MIN + 1
  ].freeze
  RANDOM = Random.new(20_261_018).then { |r| Array.new(40) { Int32.wrap(r.rand(-(2**40)..(2**40))) } }.freeze
  VALUES = (EDGES + RANDOM).freeze
  SHIFTS = [-33, -1, 0, 1, 4, 15, 16, 31, 32, 33, 64].freeze
  FRACTION_BITS = [0, 1, 8, 16, 31, 32].freeze

  # Dividing by zero follows the console's own divide routine, written out: [name, a, b, c] and
  # the answer.
  BY_ZERO = [[["div", 7, 0, 0], 1], [["div", -7, 0, 0], -1], [["div", 0, 0, 0], 1], [["mod", 7, 0, 0], 7],
             [["mod", -7, 0, 0], -7], [["div_fix", 3 << 16, 0, 16], 1], [["div_fix", -(3 << 16), 0, 16], -1]].freeze

  module_function

  def expected(name, a, b, c)
    case name
    when "add", "sub", "mul", "div", "mod", "bit_and", "bit_or", "bit_xor", "shift_left", "shift_right"
      Int32.public_send(name, a, b)
    when "neg", "bit_not" then Int32.public_send(name, a)
    when "abs" then a.negative? ? Int32.neg(a) : a
    when "clamp" then [[a, b].max, c].min
    when "mul_fix", "div_fix" then Int32.public_send(name, a, b, c)
    when "lt" then Int32.cmp(a, b) < 0 ? 1 : 0
    when "le" then Int32.cmp(a, b) <= 0 ? 1 : 0
    when "gt" then Int32.cmp(a, b) > 0 ? 1 : 0
    when "ge" then Int32.cmp(a, b) >= 0 ? 1 : 0
    when "eq" then Int32.cmp(a, b).zero? ? 1 : 0
    when "ne" then Int32.cmp(a, b).zero? ? 0 : 1
    when "both" then !a.zero? && !b.zero? ? 1 : 0
    when "either" then !a.zero? || !b.zero? ? 1 : 0
    when "to_byte" then ListValue.new(1, width: :byte).tap { |l| l.push(a) }.get(0)
    when "to_half" then ListValue.new(1, width: :half).tap { |l| l.push(a) }.get(0)
    end
  end

  # Every calculation as [name, a, b, c]. A fraction is tried with every value, not only the
  # edges: a product past 2**53 is where a float would round, and the random values reach it.
  def cases
    pairs = VALUES.product(VALUES)
    two = %w[add sub mul bit_and bit_or bit_xor lt le gt ge eq ne both either].product(pairs)
    one = %w[neg abs bit_not to_byte to_half].product(VALUES.map { |a| [a, 0] })
    dividing = %w[div mod].product(pairs.reject { |_, b| b.zero? })
    shifting = %w[shift_left shift_right].product(VALUES.product(SHIFTS))
    clamps = VALUES.product(EDGES.first(8), EDGES.first(8)).map { |a, lo, hi| ["clamp", a, lo, hi] }
    fractions = %w[mul_fix div_fix].flat_map do |name|
      VALUES.product(VALUES, FRACTION_BITS).reject { |_, b, _| name == "div_fix" && b.zero? }
            .map { |a, b, bits| [name, a, b, bits] }
    end
    (two + one + dividing + shifting).map { |name, (a, b)| [name, a, b, 0] } + clamps + fractions
  end

  # The cases a runtime got wrong, as sentences, given its answers in the same order.
  def wrong_answers(cases, answers)
    cases.zip(answers).reject { |(name, a, b, c), got| expected(name, a, b, c) == got }.map do |(name, a, b, c), got|
      "#{name}(#{a}, #{b}, #{c}) gave #{got}, Int32 gives #{expected(name, a, b, c)}"
    end
  end
end

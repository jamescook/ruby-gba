# frozen_string_literal: true

require "test_helper"

# The C arithmetic (runtime/rg_int32.h) gives the answer IR::Int32 gives, for the values where
# C and Ruby are most likely to part ways: the ends of the range, either side of nought, powers
# of two, and shift counts on and past the edge — every pair of them, plus a spread of random
# ones. Int32 is the answer key for the arithmetic. The helpers it has no function for (a
# comparison, joining two conditions, a narrow list slot) are answered the way the interpreter
# answers them, each said once in #expected.
#
# Every calculation goes through one compiled program, once at each of the two settings the
# native backend is built at: unoptimised with every undefined-behaviour check on (a check that
# fires stops the program, and the test with it), and optimised the way a release is.
class TestNativeInt32Helpers < Minitest::Test
  # Starts child processes (zig, and the program it builds), which Ruby cannot do from inside a
  # Ractor — the spawn waits for ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  Int32 =RubyGBA::IR::Int32
  Zig = RubyGBA::IR::Backends::Native::Zig
  ListValue = RubyGBA::IR::Backends::Reference::ListValue
  HARNESS = Ractor.make_shareable(File.expand_path("int32_harness.c", __dir__))

  EDGES = [
    0, 1, -1, 2, -2, 3, -7, 7, 64, -64, 127, 128, -128, -129, 255, 256,
    0x7FFF, 0x8000, -0x8000, 0xFFFF, 0x1_0000, -0x1_0000, 98_304, -98_304,
    1 << 30, -(1 << 30), Int32::MAX, Int32::MAX - 1, Int32::MIN, Int32::MIN + 1
  ].freeze
  RANDOM = Random.new(20_261_011).then { |r| Array.new(40) { Int32.wrap(r.rand(-(2**40)..(2**40))) } }.freeze
  VALUES = (EDGES + RANDOM).freeze
  SHIFTS = [-33, -1, 0, 1, 4, 15, 16, 31, 32, 33, 64].freeze
  FRACTION_BITS = [0, 1, 8, 16, 31, 32].freeze

  # The answer key for each helper: the Int32 function, or the interpreter's own reading, for
  # the ones that are not arithmetic (a comparison is 1 or 0; a narrow list slot is a list).
  def self.expected(name, a, b, c)
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

  # Every calculation as [name, a, b, c].
  def self.cases
    pairs = VALUES.product(VALUES)
    two = %w[add sub mul bit_and bit_or bit_xor lt le gt ge eq ne both either].product(pairs)
    one = %w[neg abs bit_not to_byte to_half].product(VALUES.map { |a| [a, 0] })
    dividing = %w[div mod].product(pairs.reject { |_, b| b.zero? })
    shifting = %w[shift_left shift_right].product(VALUES.product(SHIFTS))
    clamps = VALUES.product(EDGES.first(8), EDGES.first(8)).map { |a, lo, hi| ["clamp", a, lo, hi] }
    fractions = %w[mul_fix div_fix].flat_map do |name|
      EDGES.product(EDGES, FRACTION_BITS).reject { |_, b, _| name == "div_fix" && b.zero? }
           .map { |a, b, bits| [name, a, b, bits] }
    end
    (two + one + dividing + shifting).map { |name, (a, b)| [name, a, b, 0] } + clamps + fractions
  end

  CASES = cases.freeze

  def test_every_helper_gives_int32s_answer_with_every_check_on
    assert_matches_int32 :checked
  end

  def test_every_helper_gives_int32s_answer_optimised
    assert_matches_int32 :fast
  end

  # Dividing by zero follows the console's own divide routine, so a game that does it behaves
  # the same on the desktop as on the cartridge. Int32 raises here today, so these answers are
  # the console's, written out.
  def test_dividing_by_zero_gives_the_consoles_answer
    answers = calculate(:checked, [["div", 7, 0, 0], ["div", -7, 0, 0], ["div", 0, 0, 0],
                                   ["mod", 7, 0, 0], ["mod", -7, 0, 0],
                                   ["div_fix", 3 << 16, 0, 16], ["div_fix", -(3 << 16), 0, 16]])

    assert_equal [1, -1, 1, 7, -7, 1, -1], answers
  end

  private

  def assert_matches_int32(mode)
    answers = calculate(mode, CASES)
    wrong = CASES.zip(answers).reject { |(name, a, b, c), got| self.class.expected(name, a, b, c) == got }

    assert_empty wrong.first(10).map { |(name, a, b, c), got|
      "#{name}(#{a}, #{b}, #{c}) gave #{got}, Int32 gives #{self.class.expected(name, a, b, c)}"
    }, "#{wrong.size} of #{CASES.size} calculations disagree"
  end

  def calculate(mode, cases)
    exe = Zig.compile_without_sdl([HARNESS], mode: mode)
    input = cases.map { |name, a, b, c| "#{name} #{a} #{b} #{c}\n" }.join
    Zig.run_program(exe, input: input).lines.map(&:to_i)
  end
end

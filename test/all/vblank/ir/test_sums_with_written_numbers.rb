# frozen_string_literal: true

require "test_helper"

# A SUM WITH ONE SIDE A NUMBER WRITTEN IN THE PROGRAM, at the values where working it out a byte
# at a time is most likely to go wrong: either side of nought, the edges of a byte and of two
# bytes, the ends of the range. A lowering may work such a sum out where the number is, rather
# than through the sum it uses for two numbers it cannot know: a shift by a whole number of
# bytes as bytes moved, an AND with 0xFFFF on only the two low bytes of the other side, a
# comparison with the number's bytes in the instructions. Every one of them is held here to what
# IR::Int32 says.
#
# Each pass of the game loop takes the next value (and a second, from further along the list, for
# the sums of two variables) and works every sum out; the answers are read at the end of each
# pass.
class TestSumsWithWrittenNumbers < Minitest::Test
  include VBlank::IR::Build

  Int32 = VBlank::IR::Int32

  VALUES = [
    0, 1, -1, 2, 7, -7, 127, 128, -128, -129, 255, 256, -256, 257, 0x7FFF, 0x8000, -0x8000, 0x8001,
    0xFFFF, 0x1_0000, -0x1_0000, 0xFF_FF00, 0x1234_5678, -0x1234_5678, Int32::MAX, Int32::MIN, Int32::MIN + 1
  ].freeze
  # The second value of each pass.
  OTHERS = VALUES.rotate(5).freeze

  SHIFTS = [0, 1, 3, 4, 7, 8, 9, 12, 15, 16, 17, 23, 24, 25, 31, 32, 33, 40, -1].freeze

  # A table kept a byte to an entry, without its sign, picked from by the value's low bits.
  BYTES = [0, 1, 2, 7, 128, 200, 254, 255].freeze

  # Each sum, as the program works it out from the variables v and w, and as Ruby does from
  # their numbers. A comparison's answer is 1 or 0.
  def self.sums
    v = VBlank::IR::Build.var_ref(:v)
    w = VBlank::IR::Build.var_ref(:w)
    b = VBlank::IR::Build
    n = ->(number) { b.int(number) }
    shifts = SHIFTS.flat_map do |count|
      [[b.binop(:>>, v, n[count]), ->(x, _) { Int32.shift_right(x, count) }],
       [b.binop(:<<, v, n[count]), ->(x, _) { Int32.shift_left(x, count) }]]
    end
    halves = [0, 1, 7, 8, 9, 16, 24, 31].map { |bits| [b.shift_right(v, bits), ->(x, _) { Int32.shift_right(x, bits) }] }
    masks = [0xFFFF, 0xFF, 0xFF00, 0x00FF_00FF, 0x7FFF_FFFF, -256, 0, -1].product(%i[& | ^]).map do |mask, op|
      [b.binop(op, v, n[mask]), ->(x, _) { Int32.wrap(x.public_send(op, mask)) }]
    end
    within = ->(x, mask) { Int32.wrap(x) & mask }
    low = [
      [b.binop(:&, n[0xF0], v), ->(x, _) { x & 0xF0 }],
      [b.binop(:&, b.binop(:+, v, n[0x8000]), n[0xFFFF]), ->(x, _) { within[x + 0x8000, 0xFFFF] }],
      [b.binop(:&, b.binop(:-, v, n[300]), n[0xFFFF]), ->(x, _) { within[x - 300, 0xFFFF] }],
      [b.binop(:&, b.binop(:-, n[700], v), n[0xFFFF]), ->(x, _) { within[700 - x, 0xFFFF] }],
      [b.binop(:&, b.binop(:+, v, w), n[0xFFFF]), ->(x, y) { within[x + y, 0xFFFF] }],
      [b.binop(:&, b.binop(:-, v, w), n[0xFFFF]), ->(x, y) { within[x - y, 0xFFFF] }],
      [b.binop(:&, b.binop(:-, v, w), n[0xFF]), ->(x, y) { within[x - y, 0xFF] }],
      [b.binop(:&, b.binop(:^, v, w), n[0xFF]), ->(x, y) { within[x ^ y, 0xFF] }],
      [b.binop(:&, b.binop(:|, v, w), n[0xFFFF]), ->(x, y) { within[x | y, 0xFFFF] }],
      [b.binop(:&, b.binop(:&, v, w), n[0xFF00]), ->(x, y) { within[x & y, 0xFF00] }],
      [b.binop(:&, b.binop(:>>, v, n[8]), n[0xFF]), ->(x, _) { within[x >> 8, 0xFF] }],
      [b.binop(:&, b.binop(:>>, v, n[16]), n[0xFFFF]), ->(x, _) { within[x >> 16, 0xFFFF] }],
      [b.binop(:&, b.binop(:>>, v, n[24]), n[0xFFFF]), ->(x, _) { within[x >> 24, 0xFFFF] }],
      [b.binop(:&, b.binop(:>>, v, n[12]), n[0xFFFF]), ->(x, _) { within[x >> 12, 0xFFFF] }],
      [b.binop(:&, b.binop(:+, b.binop(:>>, v, n[8]), w), n[0xFFFF]), ->(x, y) { within[(x >> 8) + y, 0xFFFF] }],
      [b.binop(:&, b.binop(:+, b.binop(:*, v, n[3]), w), n[0xFFFF]), ->(x, y) { within[(x * 3) + y, 0xFFFF] }],
      [b.binop(:&, b.binop(:^, b.binop(:+, v, n[1]), b.binop(:-, w, n[1])), n[0xFFFF]),
       ->(x, y) { within[(x + 1) ^ (y - 1), 0xFFFF] }],
      [b.binop(:-, b.binop(:&, b.binop(:+, v, n[0x8000]), n[0xFFFF]), n[0x8000]),
       ->(x, _) { within[x + 0x8000, 0xFFFF] - 0x8000 }],
      [b.binop(:>>, b.binop(:-, v, w), n[8]), ->(x, y) { Int32.shift_right(Int32.sub(x, y), 8) }],
      [b.binop(:<<, b.binop(:^, v, w), n[9]), ->(x, y) { Int32.shift_left(x ^ y, 9) }]
    ]
    byte_entry = b.table_get(:bytes, b.binop(:&, v, n[BYTES.length - 1]))
    products = [
      [b.binop(:*, b.binop(:&, v, n[0xFF]), w), ->(x, y) { Int32.mul(x & 0xFF, y) }],
      [b.binop(:*, w, b.binop(:&, n[0x7F], v)), ->(x, y) { Int32.mul(y, x & 0x7F) }],
      [b.binop(:*, b.binop(:&, v, n[0xFF]), b.binop(:&, w, n[0xFF])), ->(x, y) { (x & 0xFF) * (y & 0xFF) }],
      [b.binop(:*, byte_entry, w), ->(x, y) { Int32.mul(BYTES[x & (BYTES.length - 1)], y) }],
      [b.binop(:*, v, w), ->(x, y) { Int32.mul(x, y) }]
    ]
    orderings = [[:<, 7], [:<=, -7], [:>, 255], [:>=, -129], [:<, 0x8000], [:>, -0x8000], [:<, 0], [:>=, 0],
                 [:>, Int32::MAX], [:<=, Int32::MAX], [:>=, Int32::MIN], [:<, Int32::MIN], [:==, 256], [:!=, -1]]
    asked = ->(x, op, k) { Int32.cmp(x, k).public_send(op, 0) ? 1 : 0 }
    compared = orderings.flat_map do |op, k|
      [[b.binop(op, v, n[k]), ->(x, _) { asked[x, op, k] }],
       [b.binop(op, n[k], v), ->(x, _) { asked[Int32.wrap(k), op, x] }],
       [b.binop(op, b.binop(:>>, v, n[8]), n[k]), ->(x, _) { asked[x >> 8, op, k] }],
       [b.binop(op, b.binop(:+, v, w), n[k]), ->(x, y) { asked[Int32.add(x, y), op, k] }]]
    end
    shifts + halves + masks + low + products + compared
  end

  def test_every_sum_with_a_written_number_gives_what_int32_gives
    wrong = wrong_answers(self.class.sums)

    assert_empty wrong.first(20), "#{wrong.size} sums were wrong; the first of them are listed"
  end

  # The same comparisons asked as tests rather than as numbers: each sets its answer as a
  # branch does.
  def test_every_comparison_with_a_written_number_branches_as_int32_says
    tests = self.class.sums.select { |node, _| node.kind == :binop && %i[< <= > >= == !=].include?(node.op) }
    wrong = wrong_answers(tests, branching: true)

    assert_empty wrong.first(20), "#{wrong.size} tests branched the wrong way; the first of them are listed"
  end

  private

  # Each of +sums+ ([the sum, Ruby's answer]) the game got wrong on a pass, said for a person.
  def wrong_answers(sums, branching: false)
    seen = answers_by_pass(sums.map(&:first), branching: branching)
    VALUES.zip(OTHERS).each_with_index.flat_map do |(x, y), pass|
      sums.each_with_index.filter_map do |(node, want), k|
        got = seen.fetch(pass)[k]
        "#{said(node)} with v=#{x}, w=#{y} gave #{got}, not #{want[x, y]}" unless got == want[x, y]
      end
    end
  end

  # Each pass's answers to +sums+, by pass, read as the pass waits for the screen. Branching,
  # each is asked as a test, setting 1 when it holds and 0 when it does not.
  def answers_by_pass(sums, branching: false)
    names = sums.each_index.map { |k| :"answer#{k}" }
    working = sums.zip(names).map do |sum, name|
      next set(name, sum) unless branching

      if_(sum, set(name, 1)).tap { |branch| branch.else = else_(set(name, 0)) }
    end
    game = program(
      screen(:bitmap),
      table(:values, VALUES, width: :word, signed: true),
      table(:others, OTHERS, width: :word, signed: true),
      table(:bytes, BYTES, width: :byte, signed: false),
      set(:pass, 0),
      loop_(
        set(:v, table_get(:values, var_ref(:pass))),
        set(:w, table_get(:others, var_ref(:pass))),
        *working,
        add(:pass, 1),
        wait_vblank
      )
    )
    seen = []
    player = game_player
    player.each_vblank { seen << names.map { |name| player[name] } }
    player.run(game, frames: VALUES.length)
    seen
  end

  # +node+ as a person would write it, for a failure to name the sum.
  def said(node)
    case node.kind
    when :int then node.value.to_s
    when :var_ref then node.name.to_s
    when :shift_right then "shift_right(#{said(node.operand)}, #{node.bits})"
    else "(#{said(node.lhs)} #{node.op} #{said(node.rhs)})"
    end
  end
end

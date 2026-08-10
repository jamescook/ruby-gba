# frozen_string_literal: true

require "test_helper"

# Is a number always even, always odd, or could it be either?
#
# A game that lays its world out on a grid writes `cell * 8`, and eight times anything is
# even however the game works `cell` out. Proving that lets the tear-free screen emit one
# shape of a rectangle's rows instead of both, and lets the cost model price the one that
# runs instead of the dearer of the two — an odd row costs about three times an even one.
#
# HALF THIS FILE IS ABOUT REFUSING TO ANSWER, and that half matters more. Calling a column
# even that can be odd would emit code that splices the wrong pixels and an estimate under
# what the game costs, which is the one failure the cost model exists to prevent. So the
# tests below come in pairs: what it proves, and the near-miss it must stay quiet about.
class TestIRParity < Minitest::Test
  include RubyGBA::IR::Build

  Parity = RubyGBA::IR::Parity

  def assert_even(value, msg = nil) = assert_equal(:even, Parity.of(value), msg)
  def assert_odd(value, msg = nil) = assert_equal(:odd, Parity.of(value), msg)
  def assert_unknown(value, msg = nil) = assert_nil(Parity.of(value), msg)

  # --- numbers written into the program ---

  def test_a_number_written_into_the_program_is_known_either_way
    assert_even int(40)
    assert_odd int(41)
    assert_even int(0)
  end

  # Ruby's own answer for a negative number, which is the one the DSL author expects: a
  # column of -3 is odd, and -4 is even.
  def test_a_negative_number_is_known_the_same_way
    assert_odd int(-3)
    assert_even int(-4)
  end

  # The pricing side is handed rect sides that are sometimes plain Ruby Integers and
  # sometimes value nodes, so both have to answer.
  def test_a_plain_integer_answers_like_a_written_in_number
    assert_even 40
    assert_odd 41
  end

  # --- what the game works out ---

  def test_a_variable_could_hold_anything
    assert_unknown var_ref(:x)
  end

  # THE ONE THAT PAYS FOR ITSELF: an even number times anything is even, because the two is
  # still in there whatever it is multiplied by. This is what a grid game writes.
  def test_an_even_number_times_anything_is_even
    assert_even binop(:*, var_ref(:cell), int(8))
    assert_even binop(:*, int(8), var_ref(:cell)), "either way round"
    assert_even binop(:*, var_ref(:a), binop(:*, var_ref(:b), int(2))), "however deep it is"
  end

  # ...and the near miss. Three times a number is even or odd as that number is, so there
  # is nothing to say about it.
  def test_an_odd_number_times_something_unknown_stays_unknown
    assert_unknown binop(:*, var_ref(:cell), int(3))
    assert_unknown binop(:*, var_ref(:cell), int(1))
  end

  def test_two_odd_numbers_multiplied_are_odd
    assert_odd binop(:*, int(3), int(5))
  end

  # Adding keeps the parity when both sides are known — and an even offset on an even
  # column is the other half of what a grid game writes (`cell * 8 + margin`).
  def test_adding_and_subtracting_combine_two_known_sides
    assert_even binop(:+, binop(:*, var_ref(:cell), int(8)), int(40))
    assert_odd binop(:+, binop(:*, var_ref(:cell), int(8)), int(41))
    assert_odd binop(:-, binop(:*, var_ref(:cell), int(8)), int(1))
    assert_even binop(:+, int(3), int(5)), "two odd numbers make an even one"
  end

  # The near miss: one unknown side moves the answer as much as it likes.
  def test_adding_something_unknown_gives_up
    assert_unknown binop(:+, binop(:*, var_ref(:cell), int(8)), var_ref(:margin))
    assert_unknown binop(:-, int(40), var_ref(:margin))
  end

  # The other way round leaves the same number of ones behind.
  def test_the_opposite_of_a_number_keeps_its_parity
    assert_even neg(binop(:*, var_ref(:cell), int(8)))
    assert_odd neg(int(41))
  end

  # What is left over after taking whole multiples of an even number out of an even number
  # is even — a grid coordinate wrapped onto the map (`cell * 8 % 64`).
  def test_wrapping_an_even_number_onto_an_even_range_stays_even
    assert_even binop(:%, binop(:*, var_ref(:cell), int(8)), int(64))
  end

  # The near misses around it. An odd number wrapped onto anything, or anything wrapped
  # onto an odd range, can land either way.
  def test_wrapping_gives_up_unless_both_sides_are_even
    assert_unknown binop(:%, var_ref(:x), int(2)), "the answer is 0 or 1 — that is the point"
    assert_unknown binop(:%, binop(:*, var_ref(:c), int(8)), int(9))
    assert_unknown binop(:%, int(41), int(64))
  end

  # --- everything else stays unknown, and stays unknown by DEFAULT ---

  # Dividing throws away the very bit this asks about, so there is nothing left to read.
  def test_dividing_gives_up
    assert_unknown binop(:/, binop(:*, var_ref(:cell), int(8)), int(2))
    assert_unknown binop(:/, int(40), int(4)), "even a pair of written-in numbers"
  end

  def test_a_comparison_is_a_yes_or_no_and_could_be_either
    assert_unknown binop(:<, var_ref(:x), int(10))
    assert_unknown binop(:and, var_ref(:x), var_ref(:y))
  end

  # A value read out of a list or a table is whatever was put there.
  def test_a_value_read_from_somewhere_else_gives_up
    assert_unknown list_get(:xs, int(0))
    assert_unknown table_get(:sin, var_ref(:angle))
    assert_unknown held(:left)
  end

  # THE SAFETY RULE ITSELF. Nothing is proved by being unrecognized: a kind of expression
  # this has never heard of comes back unknown, so adding one to the IR can never quietly
  # turn into a wrong proof here. Every :value kind is asked, and the handful with rules
  # of their own above are the only ones that answer.
  def test_every_other_kind_of_value_answers_unknown
    proven = %i[int binop neg]
    kinds = RubyGBA::IR::Nodes.by_kind.select { |_, type| type.category == :value }.keys - proven
    kinds.each do |kind|
      assert_nil Parity.of(RubyGBA::IR::Nodes.build(kind)),
                 "#{kind} has no parity rule, so it must not claim one"
    end
    refute_empty kinds
  end

  # And the same default inside a binop: an operator with no rule is unknown even when
  # both of its sides are known exactly.
  def test_an_operator_with_no_rule_is_unknown_with_both_sides_known
    assert_unknown binop(:>>, int(40), int(1))
    assert_unknown binop(:nonsense, int(40), int(40))
  end

  # The convenience the callers actually use, and it must never be true by accident.
  def test_asking_only_whether_it_is_even
    assert Parity.even?(binop(:*, var_ref(:cell), int(8)))
    refute Parity.even?(var_ref(:x)), "not proved even is not the same as proved odd"
    refute Parity.even?(int(41))
  end
end

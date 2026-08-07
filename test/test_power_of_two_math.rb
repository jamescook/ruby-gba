# frozen_string_literal: true

require "test_helper"

require_relative "differential"

# Dividing, multiplying and wrapping by a power of two — the arithmetic the console can
# do for nothing, and the one new operator that lets a program ask for a wrap at all.
#
# Nothing here is a new spelling: the DSL gains `%`, which a Ruby programmer already
# writes, and `/` and `*` are unchanged. The speed comes from the lowering recognising
# the divisor, so these tests care about two things — that the ANSWERS are right
# (especially on negatives, where the shortcut and the honest routine round differently)
# and that the shortcut is actually being taken.
class TestPowerOfTwoMath < Minitest::Test
  include Differential

  # Markers sit at `answer + OFFSET` so a negative answer still lands on screen.
  OFFSET = 100

  def build(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A program whose marker x is `answer + OFFSET`. Returns [program, marker_x].
  def answer_program(&block)
    program = build do
      screen :bitmap
      clear_screen :blue
      answer = instance_exec(&block)
      draw_rect_at answer + OFFSET, 40, 2, 2, Color.resolve(:red)
      halt
    end
    screen = Reference.new.run(program).screen
    [program, (0...240).find { |x| screen.pixel(x, 40) == Color.resolve(:red) }]
  end

  # Assert an expression's answer, and that the console gets the same picture.
  def assert_answer(expected, &block)
    program, marker = answer_program(&block)
    assert_equal expected, marker - OFFSET
    assert_backends_agree(program)
  end

  # --- dividing: truncation toward zero survives the shortcut ---

  # An arithmetic shift rounds toward minus infinity, so a bare shift would make this
  # -2. `/` truncates toward zero everywhere else in this framework, and the shortcut is
  # only allowed if it keeps doing that.
  def test_a_negative_numerator_divided_by_a_power_of_two_truncates_toward_zero
    assert_answer(-1) { var(:n, -7) / 4 }
  end

  def test_the_same_division_by_a_divisor_no_shift_can_reduce
    assert_answer(-2) { var(:n, -7) / 3 }
  end

  def test_a_positive_numerator_is_unaffected
    assert_answer(1) { var(:n, 7) / 4 }
  end

  # The boundary: a numerator that divides exactly must not be nudged by the correction.
  def test_a_numerator_that_divides_exactly_is_not_nudged
    assert_answer(-2) { var(:n, -8) / 4 }
    assert_answer(2) { var(:n, 8) / 4 }
  end

  def test_dividing_by_a_large_power_of_two
    assert_answer(-1) { var(:n, -65_536) / 65_536 }
    assert_answer(0) { var(:n, -65_535) / 65_536 } # toward zero, so 0 and not -1
  end

  # --- multiplying ---

  def test_multiplying_by_a_power_of_two
    assert_answer(-24) { var(:n, -3) * 8 }
    assert_answer(24) { var(:n, 3) * 8 }
  end

  # --- wrapping ---

  # The reason `%` exists: an angle that stepped below zero belongs near a full turn,
  # not at -1. Ruby's `%` already means that, so nothing new has to be learned.
  def test_wrapping_a_value_that_went_below_zero
    assert_answer(63) { var(:a, -1) % 64 }
    assert_answer(60) { var(:a, -4) % 64 }
  end

  def test_wrapping_a_value_inside_the_range_leaves_it_alone
    assert_answer(5) { var(:a, 5) % 64 }
    assert_answer(0) { var(:a, 0) % 64 }
  end

  def test_wrapping_past_the_top_of_the_range
    assert_answer(1) { var(:a, 65) % 64 }
  end

  # The same meaning when the size is not a power of two, where it is a real division
  # and the leftover the hardware hands back has the wrong sign to use directly.
  def test_wrapping_onto_a_size_that_is_not_a_power_of_two
    assert_answer(2) { var(:a, -7) % 3 }
    assert_answer(1) { var(:a, 7) % 3 }
    assert_answer(0) { var(:a, 9) % 3 }
  end

  # A negative size is unusual but Ruby defines it, so both backends must agree.
  def test_wrapping_onto_a_negative_size
    assert_answer(-2) { var(:a, 7) % -3 }
  end

  # --- the shortcut is actually taken ---

  # If the reduction silently stopped happening the answers above would all still pass,
  # because the honest routine computes the same thing. This is what notices.
  def emitted_bytes(&block)
    RubyGBA::IR::Backends::GBA.new.lower(build(&block)).bytesize
  end

  def test_a_divide_by_a_power_of_two_emits_less_than_one_by_a_computed_divisor
    fixed = emitted_bytes do
      screen :bitmap
      n = var :n, 100
      var(:out, 0).set(n / 256)
      halt
    end
    computed = emitted_bytes do
      screen :bitmap
      n = var :n, 100
      d = var :d, 256
      var(:out, 0).set(n / d)
      halt
    end

    assert_operator fixed, :<, computed,
                    "a divide by a power of two should shift, not call the divide routine"
  end

  def test_a_multiply_and_a_wrap_by_a_power_of_two_emit_less_than_computed_ones
    [->(n, d) { n * d }, ->(n, d) { n % d }].each do |op|
      fixed = emitted_bytes do
        screen :bitmap
        n = var :n, 100
        var(:out, 0).set(op.call(n, 64))
        halt
      end
      computed = emitted_bytes do
        screen :bitmap
        n = var :n, 100
        d = var :d, 64
        var(:out, 0).set(op.call(n, d))
        halt
      end

      assert_operator fixed, :<, computed
    end
  end

  # A divisor that is not a power of two has no shift to reduce to. It is reduced a
  # different way (see TestConstantDivision), and that way is dearer than a shift — so
  # a power of two must stay the cheapest of them.
  def test_a_power_of_two_divisor_beats_one_that_is_not
    two = emitted_bytes do
      screen :bitmap
      n = var :n, 100
      var(:out, 0).set(n / 256)
      halt
    end
    three = emitted_bytes do
      screen :bitmap
      n = var :n, 100
      var(:out, 0).set(n / 100)
      halt
    end

    assert_operator two, :<, three
  end
end

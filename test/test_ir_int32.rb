# frozen_string_literal: true

require "test_helper"

# Pins the IR's integer contract: signed 32-bit two's-complement with
# wraparound, signed ordering. Every backend (register-based today, a float64
# interpreter later) must agree with this.
class TestIRInt32 < Minitest::Test
  Int32 = RubyGBA::IR::Int32

  def test_signed_32bit_range
    assert_equal(-2_147_483_648, Int32::MIN)
    assert_equal 2_147_483_647, Int32::MAX
  end

  def test_wrap_leaves_in_range_values_alone
    assert_equal 0, Int32.wrap(0)
    assert_equal 100, Int32.wrap(100)
    assert_equal(-5, Int32.wrap(-5))
    assert_equal Int32::MAX, Int32.wrap(Int32::MAX)
    assert_equal Int32::MIN, Int32.wrap(Int32::MIN)
  end

  def test_wrap_reads_the_top_bit_as_sign
    assert_equal Int32::MIN, Int32.wrap(0x8000_0000) # most-negative, not big positive
    assert_equal(-1, Int32.wrap(0xFFFF_FFFF))        # all ones is -1
    assert_equal 0, Int32.wrap(0x1_0000_0000)        # 2**32 wraps to 0
  end

  # --- the acceptance criterion: a wrapping add ---
  def test_add_wraps_at_the_positive_boundary
    assert_equal Int32::MIN, Int32.add(Int32::MAX, 1) # 2**31 - 1  + 1  ->  -2**31
  end

  def test_sub_wraps_at_the_negative_boundary
    assert_equal Int32::MAX, Int32.sub(Int32::MIN, 1) # -2**31 - 1  ->  2**31 - 1
  end

  def test_mul_wraps
    assert_equal 12, Int32.mul(3, 4)
    assert_equal 0, Int32.mul(0x1_0000, 0x1_0000)     # 2**32 wraps to 0
    assert_equal Int32::MIN, Int32.mul(0x4000_0000, 2) # 2**31 wraps to -2**31
  end

  def test_neg_of_min_stays_min
    # -(-2**31) = 2**31, which has no positive representation and wraps back —
    # the classic two's-complement edge every backend must reproduce.
    assert_equal Int32::MIN, Int32.neg(Int32::MIN)
    assert_equal(-5, Int32.neg(5))
  end

  # --- mul_fix: the multiply whose product is formed at full width ---

  # The case the operation exists for. 1.5 with 16 fraction bits is 98304; the two
  # multiplied together make 9,663,676,416, which a 32-bit number cannot hold, so a
  # plain multiply wraps and the answer that comes out is not 2.25.
  def test_mul_fix_survives_a_product_too_big_for_32_bits
    one_and_a_half = 3 * 65_536 / 2

    assert_equal 2.25 * 65_536, Int32.mul_fix(one_and_a_half, one_and_a_half, 16)
    refute_equal Int32.mul_fix(one_and_a_half, one_and_a_half, 16),
                 Int32.mul(one_and_a_half, one_and_a_half) >> 16
  end

  def test_mul_fix_keeps_the_scale_it_was_given
    assert_equal 65_536, Int32.mul_fix(65_536, 65_536, 16) # 1.0 * 1.0 = 1.0
    assert_equal 256, Int32.mul_fix(256, 256, 8)           # the same in 8 fraction bits
    assert_equal 12, Int32.mul_fix(3, 4, 0)                # no fraction bits: a plain multiply
  end

  def test_mul_fix_carries_the_sign_through
    one_and_a_half = 3 * 65_536 / 2

    assert_equal(-2.25 * 65_536, Int32.mul_fix(-one_and_a_half, one_and_a_half, 16))
    assert_equal 2.25 * 65_536, Int32.mul_fix(-one_and_a_half, -one_and_a_half, 16)
  end

  # Rounding is DOWN, not toward zero — the arithmetic shift every backend uses.
  # So a small negative product lands at -1 rather than 0, and the interpreter has
  # to agree with the console about that.
  def test_mul_fix_rounds_down_rather_than_toward_zero
    assert_equal(-1, Int32.mul_fix(-1, 65_536, 16))
    assert_equal 0, Int32.mul_fix(1, 1, 16) # the smallest fraction squared vanishes
  end

  # The result is still a 32-bit value. What mul_fix removes is the overflow on the
  # WAY to the answer, not the wrap of an answer that genuinely doesn't fit.
  def test_mul_fix_still_wraps_a_result_that_does_not_fit
    assert_equal 0, Int32.mul_fix(1 << 20, 1 << 20, 8) # 2**40 >> 8 is 2**32, which wraps to 0
  end

  # --- the acceptance criterion: a signed compare near the boundary ---
  def test_cmp_is_signed_not_unsigned
    # 0xFFFF_FFFF is -1, so it is LESS than 1 — the opposite of an unsigned
    # comparison of the raw bits.
    assert_equal(-1, Int32.cmp(0xFFFF_FFFF, 1))
    assert_equal 1, Int32.cmp(Int32::MAX, Int32::MIN) # max > min, signed
    assert_equal 0, Int32.cmp(42, 42)
  end
end

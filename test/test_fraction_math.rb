# frozen_string_literal: true

require "test_helper"

# Multiplying two numbers that hold a fraction (`times_fraction`).
#
# A variable holds whole numbers, so a program that needs halves keeps its numbers
# multiplied up — with 16 fraction bits, 1.5 is stored as 98304. Adding those works
# already. Multiplying them does not: the answer comes out multiplied up twice, and
# that intermediate is bigger than a variable can hold, so a plain `*` wraps and
# returns nonsense.
#
# These tests put the answer on screen as a marker, so what is asserted is where the
# marker landed — which is exactly what a game would get wrong.
class TestFractionMath < Minitest::Test
  ONE = 65_536          # 1.0, with 16 fraction bits
  ONE_AND_A_HALF = 3 * ONE / 2
  MARKER_Y = 40
  PER_UNIT = ONE / 20   # the marker moves 20 pixels per whole unit, so 2.25 -> x 45

  # Multiply the two numbers the given way and park a marker at the answer, scaled
  # down to pixels. `plain` picks the ordinary `*` instead, to show what it does.
  def marker_program(plain: false)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      a = var :a, ONE_AND_A_HALF
      product = var :product, 0
      product.set(plain ? a * a : a.times_fraction(a, fraction_bits: 16))
      x = var :x, 0
      x.set(product / PER_UNIT)
      draw_rect_at x, MARKER_Y, 4, 4, Color.resolve(:white)
      halt
    end
    b.emit_pending_functions
    b.program
  end

  # 1.5 * 1.5 is 2.25, so the marker stands at x 45. Getting there needs a product of
  # 9,663,676,416 on the way — four times what a variable can hold.
  def test_the_answer_lands_where_it_should_on_the_interpreter
    screen = Reference.new.run(marker_program).screen

    assert_equal Color.resolve(:white), screen.pixel(45, MARKER_Y), "1.5 * 1.5 puts the marker at 2.25"
    assert_equal 0, screen.pixel(41, MARKER_Y), "and nowhere near 2.0"
  end

  def test_the_answer_lands_in_the_same_place_on_the_console
    rom = assemble_rom(marker_program, name: "FRACMUL")
    v = assert_gemba_loads_rom(rom, frames: 4)

    assert v.pixel_is?(45, MARKER_Y, :white), "the console must agree with the interpreter"
    assert v.pixel_is?(41, MARKER_Y, :black)
  end

  # The reason the operation exists: a plain `*` on the same two numbers overflows,
  # and the marker goes somewhere else entirely — here, right off the screen. Both
  # backends have to be wrong the SAME way, which is what makes this a fair contrast
  # rather than a claim about one of them.
  def test_a_plain_multiply_overflows_and_loses_the_marker
    screen = Reference.new.run(marker_program(plain: true)).screen
    on_screen = (0...240).select { |x| screen.pixel(x, MARKER_Y) == Color.resolve(:white) }

    assert_empty on_screen, "the wrapped product puts the marker off screen"
  end

  # Both operands multiplied up by the same amount, one of them negative.
  def test_a_negative_operand_keeps_its_sign
    prog = RubyGBA::IR::Build.program(
      RubyGBA::IR::Build.set(:out, RubyGBA::IR::Build.mul_fix(
                                     RubyGBA::IR::Build.int(-ONE_AND_A_HALF),
                                     RubyGBA::IR::Build.int(ONE_AND_A_HALF), 16
                                   )),
      RubyGBA::IR::Build.halt,
    )

    assert_equal(-(2.25 * ONE), Reference.new.run(prog)[:out])
  end

  # fraction_bits is settled while building, so a nonsensical one is a build error
  # rather than a ROM that shifts by a number the chip cannot encode.
  def test_an_impossible_number_of_fraction_bits_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      RubyGBA::IR::Build.mul_fix(RubyGBA::IR::Build.int(1), RubyGBA::IR::Build.int(1), 33)
    end
    assert_match(/fraction_bits/, err.message)
    assert_match(/0 to 32/, err.message)
  end
end

# frozen_string_literal: true

require "test_helper"

require_relative "differential"

# Numbers that carry a fraction, declared by writing a Float and then carried through
# arithmetic without the program mentioning a scale again. See lib/ruby_gba/fraction.rb
# for the rules and the evidence they were argued from.
#
# The behaviour is asserted by putting the answer on screen as a marker and reading where
# it landed, so these tests say what a program DOES rather than which nodes it built.
class TestFractionType < Minitest::Test
  include Differential

  ONE = 1 << 16

  def build(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Run a program that puts `answer` (a whole number of pixels) at the marker's x.
  def marker_x(&block)
    program = build do
      screen :bitmap
      clear_screen :blue
      answer = instance_exec(&block)
      draw_rect_at answer, 40, 2, 2, Color.resolve(:red)
      halt
    end
    screen = Reference.new.run(program).screen
    (0...240).find { |x| screen.pixel(x, 40) == Color.resolve(:red) }
  end

  # --- declaring ---

  def test_a_float_declares_a_variable_that_holds_a_fraction
    b = RubyGBA::Builder.new
    speed = b.instance_eval { var :speed, 1.5 }

    assert_predicate speed, :fraction?
    assert_equal 16, speed.fraction_bits
  end

  def test_a_whole_number_declares_a_variable_that_does_not
    b = RubyGBA::Builder.new
    refute_predicate b.instance_eval { var :count, 3 }, :fraction?
  end

  # The scale is declared once and carried. A second handle for the same variable — from
  # a later `set`, in another scene — must agree, or arithmetic there would be wrong.
  def test_a_later_handle_for_the_same_variable_still_holds_a_fraction
    b = RubyGBA::Builder.new
    b.instance_eval { var :speed, 1.5 }

    assert_predicate b.instance_eval { set :speed, 2.0 }, :fraction?
  end

  # --- arithmetic that carries the fraction ---

  def test_adding_a_number_written_in_the_program_means_the_number
    assert_equal 101, marker_x { (var(:x, 100.5) + 1).to_i } # 100.5 + 1 = 101.5, dropped to 101
  end

  def test_multiplying_by_a_count_is_ordinary_multiplication
    assert_equal 105, marker_x { (var(:x, 35.2) * 3).to_i } # 35.2 * 3 = 105.6
  end

  # The one that matters. 1.5 * 1.5 is 2.25 — but scaled up twice that is 9,663,676,416,
  # four times past where a variable wraps. Nothing in the program says so.
  def test_multiplying_two_fractions_does_not_overflow
    assert_equal 90, marker_x { (var(:a, 60.0) * var(:b, 1.5)).to_i }
  end

  # ...and the contrast: the same multiply written out by hand, on whole numbers scaled
  # up the same way, wraps. 60 * 65536 times 1.5 * 65536 is 0x5A00000000, whose low 32
  # bits are all zero — so the answer is not 90 but 0, and the marker sits at the far
  # left of the screen looking like a perfectly ordinary result.
  def test_the_same_multiply_on_plain_whole_numbers_wraps
    assert_equal 0, marker_x { (var(:a, 60 * ONE) * var(:b, (1.5 * ONE).to_i)) / ONE }
  end

  def test_dividing_by_a_count_keeps_the_fraction
    assert_equal 25, marker_x { (var(:x, 100.5) / 4).to_i } # 100.5 / 4 = 25.125
  end

  # --- moving between a fraction and a whole number ---

  def test_to_i_drops_the_fraction_rounding_down
    assert_equal 100, marker_x { var(:x, 100.75).to_i }
  end

  def test_to_f_gives_a_whole_number_a_fraction_so_it_can_meet_one
    assert_equal 12, marker_x { (var(:n, 10).to_f + 2.5).to_i }
  end

  def test_to_i_on_a_whole_number_and_to_f_on_a_fraction_change_nothing
    b = RubyGBA::Builder.new
    whole = b.instance_eval { var :n, 5 }
    fraction = b.instance_eval { var :f, 5.0 }

    assert_same whole, whole.to_i
    assert_same fraction, fraction.to_f
  end

  # --- what must not compile ---

  def test_mixing_a_fraction_with_a_whole_number_the_game_works_out_is_a_build_error
    err = assert_raises(ArgumentError) do
      build do
        screen :bitmap
        var(:speed, 1.5) + var(:count, 3)
      end
    end

    assert_match(/holds a fraction/, err.message)
    assert_match(/to_f/, err.message)
    assert_match(/test_fraction_type\.rb:\d+/, err.message, "it should name the line that caused it")
  end

  def test_mixing_two_different_scales_is_a_build_error
    err = assert_raises(ArgumentError) do
      b = RubyGBA::Builder.new
      coarse = RubyGBA::Value.new(b, RubyGBA::IR::Build.var_ref(:c), name: :c, fraction_bits: 8)
      b.instance_eval { var :fine, 1.5 } + coarse
    end

    assert_match(/not the same amount/, err.message)
    assert_match(/16 bits against 8/, err.message)
  end

  # Dividing two of them keeps the fraction: 3.0 over 1.5 is 2.0, not 2, and 3.0 over 2.0
  # is 1.5 and not 1. The marker lands at the answer times ten so a fraction shows.
  def test_dividing_a_fraction_by_a_fraction_keeps_the_fraction
    assert_equal 20, marker_x { ((var(:a, 3.0) / var(:b, 1.5)) * 10).to_i }
    assert_equal 15, marker_x { ((var(:c, 3.0) / var(:d, 2.0)) * 10).to_i }
  end

  # Two that hold DIFFERENT amounts of fraction still cannot be divided, the same way
  # they cannot be added — the answer would be wrong by a factor of thousands.
  def test_dividing_fractions_of_different_scales_is_a_build_error
    err = assert_raises(ArgumentError) do
      b = RubyGBA::Builder.new
      coarse = RubyGBA::Value.new(b, RubyGBA::IR::Build.var_ref(:c), name: :c, fraction_bits: 8)
      b.instance_eval { var :fine, 3.0 } / coarse
    end

    assert_match(/not the same amount/, err.message)
  end

  def test_giving_a_whole_number_variable_a_fraction_is_a_build_error
    err = assert_raises(ArgumentError) do
      build do
        screen :bitmap
        var(:count, 3).add 1.5
      end
    end

    assert_match(/holds whole numbers/, err.message)
    assert_match(/var :name, 1.5/, err.message, "it should show how to declare it instead")
  end

  # --- the console agrees ---

  def test_the_console_computes_the_same_answers
    assert_backends_agree(build do
      screen :bitmap
      clear_screen :blue
      speed = var :speed, 1.5
      pos = var :pos, 20.25
      pos.add(speed * speed)      # 20.25 + 2.25 = 22.5 — the multiply that would overflow
      draw_rect_at pos.to_i, 40, 2, 2, Color.resolve(:red)
      draw_rect_at (pos * 4).to_i, 60, 2, 2, Color.resolve(:green) # 90
      draw_rect_at (pos / 3).to_i, 80, 2, 2, Color.resolve(:white) # 7.5 -> 7
      halt
    end)
  end

  # A fraction that goes negative rounds DOWN on the way back to a whole number, which is
  # what keeps it consistent with the multiply. Both backends must agree about that.
  def test_the_console_agrees_about_a_negative_fraction
    program = build do
      screen :bitmap
      clear_screen :blue
      pos = var :pos, 10.5
      pos.sub 11.0                                    # -0.5
      draw_rect_at pos.to_i + 100, 40, 2, 2, Color.resolve(:red) # rounds down to -1, so 99
      halt
    end

    assert_equal Color.resolve(:red), Reference.new.run(program).screen.pixel(99, 40)
    assert_backends_agree(program)
  end

  # --- tables ---

  def test_a_table_of_floats_reads_back_as_a_fraction
    assert_equal 30, marker_x {
      t = table :halves, [0.0, 1.5, 2.5]
      (t[2] * var(:n, 12)).to_i # 2.5 * 12 = 30
    }
  end
end

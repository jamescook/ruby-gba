# frozen_string_literal: true

require "test_helper"

# The Ruby the lowering prints, for the rules a mistake in it would hide rather than show: every
# test of what a game does plays the printed code, but a condition always taken or a routine
# never called would only show where some test happened to look.
class TestRubyPrinter < Minitest::Test
  private def printed(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    text, = VBlank::IR::Backends::Ruby::Lowering.new(builder.program).text_and_gaps
    text
  end

  # In Ruby nought is true, so a condition is compared with nought, a loop's included.
  def test_a_condition_is_compared_with_nought
    text = printed do
      x = var :x, 0
      game_loop { (x > 6).then { x.set! 0 } }
    end

    assert_includes text, "if rg_gt(@v_x, 6) != 0"
    assert_match(/^\s*while 1 != 0$/, text)
  end

  # What the game keeps is the game's own, from rg_game_setup on; a routine is a method, and one
  # picked by its number is called by that method's name.
  def test_a_routine_picked_by_number_is_called_by_name
    text = printed do
      which = var :which, 0
      func(:left) { which.set! 1 }
      func(:right) { which.set! 0 }
      game_loop { call %i[left right], number: which }
    end

    setup = text[/^def rg_game_setup\n.*?^end$/m]
    assert_match(/^  @v_which = 0$/, setup)
    assert_match(/^def f_left$/, text)
    assert_match(/__send__\(@r_\w+\[/, text)
  end
end

# frozen_string_literal: true

require "test_helper"

require "differential"

# THE TESTS OF vblank/dsl/test_fraction_type.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# Numbers that carry a fraction, declared by writing a Float and then carried through
# arithmetic without the program mentioning a scale again. See lib/vblank/dsl/fraction.rb
# for the rules and the evidence they were argued from.
#
# The behaviour is asserted by putting the answer on screen as a marker and reading where
# it landed, so these tests say what a program DOES rather than which nodes it built.
class TestFractionTypeOnTheAdvance < Minitest::Test
  include Differential

  ONE = 1 << 16

  private def build(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # Run a program that puts `answer` (a whole number of pixels) at the marker's x.
  private def marker_x(&block)
    program = build do
      screen :bitmap
      clear_screen :blue
      answer = instance_exec(&block)
      draw_rect_at answer, 40, 2, 2, Color.resolve(:red)
      halt
    end
    screen = game_player.run(program).screen
    (0...240).find { |x| screen.pixel(x, 40) == Color.resolve(:red) }
  end

  # --- declaring ---

  # --- arithmetic that carries the fraction ---

  # --- moving between a fraction and a whole number ---

  # --- what must not compile ---

  # --- the console agrees ---

  def test_the_console_computes_the_same_answers
    assert_backends_agree(build do
      screen :bitmap
      clear_screen :blue
      speed = var :speed, 1.5
      pos = var :pos, 20.25
      pos.add!(speed * speed)     # 20.25 + 2.25 = 22.5 — the multiply that would overflow
      draw_rect_at pos.to_i, 40, 2, 2, Color.resolve(:red)
      draw_rect_at (pos * 4).to_i, 60, 2, 2, Color.resolve(:green) # 90
      draw_rect_at (pos / 3).to_i, 80, 2, 2, Color.resolve(:white) # 7.5 -> 7
      halt
    end)
  end

  # --- tables ---

end

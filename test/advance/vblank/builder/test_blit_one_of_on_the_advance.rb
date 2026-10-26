# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test/vblank/builder/test_blit_one_of.rb whose games can paint more colours into
# one 8×8 square of the screen than a Game Boy Color's square holds — three pictures of a colour
# each at one place, on white — so they play on the Advance's runs alone.
# The friendly errors stay in that file.
#
# Drawing one of a set of pictures, picked by a number the game works out: `blit [...], x, y,
# showing: n`.
class TestBlitOneOfOnTheAdvance < Minitest::Test
  include Differential

  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)
  BLUE = Color.resolve(:blue)
  WHITE = Color.resolve(:white)

  FOUR = (["####"] * 4).join("\n")

  # Three same-size pictures and a variable that picks between them. A still picture:
  # drawn once, then held, so the two backends can be held against each other.
  private def faces_program(pick)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :white
      image(:calm, "#" => :green) { FOUR }
      image(:hurt, "#" => :blue) { FOUR }
      image(:dying, "#" => :red) { FOUR }
      state = var :state, pick
      blit %i[calm hurt dying], 40, 40, showing: state
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  private def pixel_after(pick)
    game_player.run(faces_program(pick)).screen.pixel(42, 42)
  end

  # --- it picks ---

  def test_the_number_picks_the_picture
    assert_equal GREEN, pixel_after(0)
    assert_equal BLUE, pixel_after(1)
    assert_equal RED, pixel_after(2)
  end

  # A value still settling, or one that ran off the end, must leave the screen alone rather
  # than draw a picture that is not in the set or read past the list.
  def test_a_number_outside_the_set_draws_nothing
    assert_equal WHITE, pixel_after(3), "past the end draws nothing"
    assert_equal WHITE, pixel_after(-1), "and so does below the start"
  end

  # An expression works, not just a variable — which is the case that raised this: a face
  # picked from two live numbers at once.
  def test_the_number_may_be_worked_out
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :white
      image(:calm, "#" => :green) { FOUR }
      image(:hurt, "#" => :blue) { FOUR }
      image(:dying, "#" => :red) { FOUR }
      hurt = var :hurt, 1
      look = var :look, 1
      blit %i[calm hurt dying], 40, 40, showing: hurt + look
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal RED, game_player.run(b.program).screen.pixel(42, 42),
                 "1 + 1 picked the third picture"
  end

  # --- the console draws the same thing ---

  def test_both_backends_draw_the_same_picture
    assert_backends_agree(faces_program(1), frames: 2)
  end

  def test_both_backends_agree_when_the_number_is_outside_the_set
    assert_backends_agree(faces_program(9), frames: 2)
  end
end

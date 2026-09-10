# frozen_string_literal: true

require "test_helper"
require "differential"

# DRAW ONE OF A SET OF PICTURES, PICKED BY A NUMBER THE GAME WORKS OUT.
#
# A face that watches you, a machine in four stages of wreckage, a dial drawn as a strip, a
# portrait picked by who is speaking. Written the long way that is a test and a draw per
# picture — thirty lines of bookkeeping round one line of intent, written slightly differently
# in every game that needs it. It is also exactly what this lowers to, so nothing is gained by
# writing it out.
#
# The word is the one the DSL already uses for "this value decides which": `showing:`, the same
# as on a menu row and a two-colour label.
class TestBlitOneOf < Minitest::Test
  include Differential

  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)
  BLUE = Color.resolve(:blue)
  WHITE = Color.resolve(:white)

  FOUR = (["####"] * 4).join("\n")

  # Three same-size pictures and a variable that picks between them. A still picture:
  # drawn once, then held, so the two backends can be held against each other.
  def faces_program(pick)
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
    b.emit_pending_functions
    b.program
  end

  def pixel_after(pick)
    Reference.new.run(faces_program(pick)).screen.pixel(42, 42)
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
    b.emit_pending_functions

    assert_equal RED, Reference.new.run(b.program).screen.pixel(42, 42),
                 "1 + 1 picked the third picture"
  end

  # --- the console draws the same thing ---

  def test_both_backends_draw_the_same_picture
    assert_backends_agree(faces_program(1), frames: 2)
  end

  def test_both_backends_agree_when_the_number_is_outside_the_set
    assert_backends_agree(faces_program(9), frames: 2)
  end

  # --- friendly errors ---

  def test_a_list_with_nothing_to_pick_between_them_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_with { blit %i[calm hurt], 40, 40 }
    end
    assert_match(/showing:/, error.message, "it names the word that picks")
  end

  def test_showing_on_a_single_picture_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_with { blit :calm, 40, 40, showing: 1 }
    end
    assert_match(/:calm/, error.message)
    assert_match(/showing:/, error.message)
  end

  def test_pictures_of_different_sizes_are_a_friendly_error
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        image(:calm, "#" => :green) { FOUR }
        image(:hurt, "#" => :blue) { FOUR }
        image(:odd, "#" => :red) { "##\n##" }
        blit %i[calm hurt odd], 40, 40, showing: 0
      end
    end
    assert_match(/:odd/, error.message, "it names the odd one out")
    assert_match(/2x2/, error.message)
    assert_match(/4x4/, error.message)
  end

  def test_a_picture_that_is_not_defined_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_with { blit %i[calm nobody], 40, 40, showing: 0 }
    end
    assert_match(/:nobody/, error.message)
  end

  def build_with(&block)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:calm, "#" => :green) { FOUR }
      image(:hurt, "#" => :blue) { FOUR }
      instance_eval(&block)
    end
    b
  end
end

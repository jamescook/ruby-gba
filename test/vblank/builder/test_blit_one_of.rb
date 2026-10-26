# frozen_string_literal: true

require "test_helper"

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
#
# The tests that draw the pictures can paint more colours into one 8×8 square of the screen than
# a Game Boy Color's square holds, so they are in
# test/advance/vblank/builder/test_blit_one_of_on_the_advance.rb.
class TestBlitOneOf < Minitest::Test
  FOUR = (["####"] * 4).join("\n")

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

  private def build_with(&block)
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

# frozen_string_literal: true

require "test_helper"

# The maps these tests draw, shared with the Advance cartridge's own tests of a turning background
# (test/lowering/gba/vblank/dsl/test_affine_background_cartridge.rb).
module AffineBackgroundGames
  # A 32x32 map, blank except the given (col, row) => character marks, so a
  # transform is judged by which mark lands under a fixed screen point rather than
  # by re-deriving the matrix math in the test itself.
  private def marked_map(marks)
    Array.new(32) { Array.new(32, " ") }.tap do |rows|
      marks.each { |(col, row), ch| rows[row][col] = ch }
    end.map(&:join)
  end
end

# Affine backgrounds: `screen :rotozoom` gives a background handle `rotate`/`scale`,
# the same names and units a hardware sprite's `face_angle`/`scale` already use,
# applied to a whole tiled layer instead of one picture. What a turned or resized picture
# looks like on the Advance's cartridge is in
# test/lowering/gba/vblank/dsl/test_affine_background_cartridge.rb; here are the friendly
# errors for a turn a game cannot have.
class TestAffineBackground < Minitest::Test
  include AffineBackgroundGames

  # The point is settled while the program is written. A pivot the game worked out as it
  # ran would be its own effect — a picture that turns around something that moves — and
  # saying so plainly beats half-doing it.
  def test_a_pivot_the_game_works_out_is_a_friendly_error
    map = marked_map({})
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :rotozoom
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        aim = var :aim, 40
        background(:board, tiles: :t, map: map).turns_around(aim, 80)
      end
    end

    assert_match(/turns_around/, err.message)
    assert_match(/whole number/, err.message, "it says what to write instead")
  end

  # --- guardrails: the two footguns this feature makes plain-language errors ---

  def test_rotating_a_bitmap_background_is_a_friendly_error
    map = marked_map({})
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        board = background :board, tiles: :t, map: map
        board.rotate(45)
      end
    end
    # A tile screen is what this needs, and there are two of those — a bitmap screen is
    # the one that cannot turn a background at all, because it has none to turn.
    assert_match(/has no background layer/, err.message)
    assert_match(/screen :bitmap/, err.message, "it names the screen the program is actually on")
  end

  def test_scrolling_an_affine_background_is_a_friendly_error
    map = marked_map({})
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :rotozoom
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        board = background :board, tiles: :t, map: map
        board.scroll_by(1, 0)
      end
    end
    assert_match(/rotate|scale/, err.message)
  end
end

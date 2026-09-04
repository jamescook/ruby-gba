# frozen_string_literal: true

require "test_helper"

# Affine backgrounds: `screen :affine` gives a background handle `rotate`/`scale`,
# the same names and units a hardware sprite's `face_angle`/`scale` already use,
# applied to a whole tiled layer instead of one picture. Asserted here against the
# reference interpreter's fake screen — see .claude/CLAUDE.md's testing altitude
# rule: behavior (what a turned/resized picture looks like), not the IR it builds.
class TestAffineBackground < Minitest::Test
  def interpret(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    Reference.new.run(builder.program)
  end

  # A 32x32 map, blank except the given (col, row) => character marks, so a
  # transform is judged by which mark lands under a fixed screen point rather than
  # by re-deriving the matrix math in the test itself.
  def marked_map(marks)
    Array.new(32) { Array.new(32, " ") }.tap do |rows|
      marks.each { |(col, row), ch| rows[row][col] = ch }
    end.map(&:join)
  end

  # No turn, no resize: the picture reads exactly as drawn. Column 25, row 10 (a
  # screen point 80px right of center, on the center row) shows the tile placed
  # there — the plain identity case every other assertion here is a change from.
  def test_untouched_background_reads_as_drawn
    map = marked_map({ [25, 10] => "#" })
    i = interpret do
      screen :affine
      image :white, "#" => :white do "########\n" * 8 end
      tiles :t, "#" => :white
      background :board, tiles: :t, map: map
      halt
    end

    assert_equal Color.resolve(:white), i.screen.pixel(200, 80)
  end

  # Zoom in 2x: a screen point 80px from center now samples a texture point only
  # 40px from center (stepping through the picture at half a pixel per screen
  # pixel) — column 20, not column 25.
  def test_scale_zooms_in_toward_the_center
    map = marked_map({ [25, 10] => "#", [20, 10] => "$" })
    i = interpret do
      screen :affine
      image :white, "#" => :white do "########\n" * 8 end
      image :red, "#" => :red do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :red
      board = background :board, tiles: :t, map: map
      board.scale(2.0)
      halt
    end

    assert_equal Color.resolve(:red), i.screen.pixel(200, 80)
  end

  # Turn 90 degrees clockwise: a screen point straight right of center now samples
  # a texture point straight ABOVE center instead (row 0, column 15) — turning the
  # picture, not sliding it.
  def test_rotate_turns_the_picture_around_its_center
    map = marked_map({ [25, 10] => "#", [15, 0] => "$" })
    i = interpret do
      screen :affine
      image :white, "#" => :white do "########\n" * 8 end
      image :green, "#" => :green do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :green
      board = background :board, tiles: :t, map: map
      board.rotate(90)
      halt
    end

    assert_equal Color.resolve(:green), i.screen.pixel(200, 80)
  end

  # The affine matrix is read live every frame, whether a program reaches it
  # through `rotate`/`scale` or mutates the underlying angle/scale Value directly
  # (`board.scale.approach`, the same idiom a sprite's size already supports) — see
  # Builder#affine_each_frame, registered once a background is made affine at all.
  def test_a_directly_mutated_scale_value_still_takes_effect
    map = marked_map({ [25, 10] => "#", [20, 10] => "$" })
    i = interpret do
      screen :affine
      image :white, "#" => :white do "########\n" * 8 end
      image :red, "#" => :red do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :red
      board = background :board, tiles: :t, map: map
      board.scale.set(2.0) # bypasses the #scale setter entirely
      game_loop { wait_vblank }
    end

    assert_equal Color.resolve(:red), i.screen.pixel(200, 80)
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
    assert_match(/screen :affine/, err.message)
  end

  def test_scrolling_an_affine_background_is_a_friendly_error
    map = marked_map({})
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :affine
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        board = background :board, tiles: :t, map: map
        board.scroll_by(1, 0)
      end
    end
    assert_match(/rotate|scale/, err.message)
  end
end

# frozen_string_literal: true

require "test_helper"
require "differential"

# Affine backgrounds: `screen :rotozoom` gives a background handle `rotate`/`scale`,
# the same names and units a hardware sprite's `face_angle`/`scale` already use,
# applied to a whole tiled layer instead of one picture. Asserted here against the
# reference interpreter's fake screen — see .claude/CLAUDE.md's testing altitude
# rule: behavior (what a turned/resized picture looks like), not the IR it builds.
class TestAffineBackground < Minitest::Test
  include Differential

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
      screen :rotozoom
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
      screen :rotozoom
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
      screen :rotozoom
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
  # (`board.scale.approach!`, the same idiom a sprite's size already supports) — see
  # Builder#affine_each_frame, registered once a background is made affine at all.
  def test_a_directly_mutated_scale_value_still_takes_effect
    map = marked_map({ [25, 10] => "#", [20, 10] => "$" })
    i = interpret do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      image :red, "#" => :red do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :red
      board = background :board, tiles: :t, map: map
      board.scale.set!(2.0) # bypasses the #scale setter entirely
      game_loop { wait_vblank }
    end

    assert_equal Color.resolve(:red), i.screen.pixel(200, 80)
  end

  # --- the zoom is a SIZE change, not just a different picture ---
  #
  # "The pixels changed from one frame to the next" is not evidence of a zoom: a
  # matrix that is merely wrong changes them too. What a zoom means is that the
  # squares of a checkerboard get BIGGER, so these measure the squares.

  # A checkerboard of 8x8 tiles, sized +size+.
  def checkerboard_at(size)
    rows = (0...32).map { |r| (0...32).map { |c| (r + c).even? ? "L" : "D" }.join }
    interpret do
      screen :rotozoom
      image :light, "#" => :white do "########\n" * 8 end
      image :dark, "#" => :blue do "########\n" * 8 end
      tiles :checker, "L" => :light, "D" => :dark
      board = background :board, tiles: :checker, map: rows
      board.scale(size)
      halt
    end
  end

  # How wide the checkerboard's squares read along a screen row: the run lengths of
  # same-colored pixels, dropping the first and last (those are cut by the screen edge).
  def square_widths(screen, y = 80)
    runs = []
    (0...240).each do |x|
      color = screen.pixel(x, y)
      if runs.last && runs.last.first == color
        runs.last[1] += 1
      else
        runs << [color, 1]
      end
    end
    runs[1..-2].to_a.map(&:last)
  end

  def test_scaling_up_makes_the_squares_bigger
    at_1x = square_widths(checkerboard_at(1.0).screen)
    at_2x = square_widths(checkerboard_at(2.0).screen)
    at_3x = square_widths(checkerboard_at(3.0).screen)

    assert_equal [8], at_1x.uniq, "as drawn, the squares are the tile's own 8px"
    assert_equal [16], at_2x.uniq, "twice the size: 16px squares"
    # A third of a texel per pixel is not a whole number of 256ths, so at 3x the
    # squares land a pixel either side of 24 — the console's own rounding, not slack.
    assert_empty (at_3x.uniq - [24, 25]), "three times: 24px squares, got #{at_3x.uniq.inspect}"
    # ...and fewer of them fit across the screen, which is the same fact from the
    # other side — a zoom, not a scroll or a redraw of the same picture.
    assert_operator at_3x.size, :<, at_1x.size
  end

  # A checkerboard of two colours, as a whole program, for the two tests below.
  def board_program(scale: nil)
    rows = (0...32).map { |r| (0...32).map { |c| (r + c).even? ? "L" : "D" }.join }
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :light, "#" => :white do "########\n" * 8 end
      image :dark, "#" => :blue do "########\n" * 8 end
      tiles :checker, "L" => :light, "D" => :dark
      board = background :board, tiles: :checker, map: rows
      board.scale(scale) if scale
      game_loop { wait_vblank }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_scaling_up_makes_the_squares_bigger_on_the_console
    rom = ROM.assemble(GBA.new.lower(board_program(scale: 2.0)), title: "AFFINE", code: "BAFF", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)

    runs = []
    (0...240).each do |x|
      color = v.pixel_gba(x, 80)
      if runs.last && runs.last.first == color
        runs.last[1] += 1
      else
        runs << [color, 1]
      end
    end
    assert_equal [16], runs[1..-2].map(&:last).uniq, "at twice the size the console draws 16px squares"
    # ...and they are the two colours the board was drawn from, in turn. Run LENGTHS alone
    # pass on a board of any two colours at all, which is how a board coming out black and
    # white went unnoticed.
    assert_equal [Color.resolve(:white), Color.resolve(:blue)].sort,
                 runs[1..-2].map(&:first).uniq.sort,
                 "and they are white and blue, the colours it was drawn from"
  end

  # HOW A TURNING LAYER READS ITS COLOURS, which is not a choice: that pair of hardware
  # layers reads a whole byte per pixel whatever the art is drawn from, because its map
  # holds one byte a cell with no room to name a group of sixteen colours. A board drawn
  # from two colours is the case that catches it — few enough colours to be sorted into
  # such a group, which would store the tiles at half size under a layer reading them at
  # full size: half of every tile blank, every colour after the first black.
  def test_a_turning_background_drawn_from_few_colours_draws_the_same_on_both
    assert_backends_agree(board_program, frames: 4)
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

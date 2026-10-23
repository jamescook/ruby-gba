# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_affine_background.rb whose games turn or resize a whole background, which a
# Game Boy Color's hardware cannot do, so they play on the Advance's runs alone.
class TestAffineBackgroundOnTheAdvance < Minitest::Test
  include Differential

  private def interpret(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    game_player.run(builder.program)
  end

  # A 32x32 map, blank except the given (col, row) => character marks, so a
  # transform is judged by which mark lands under a fixed screen point rather than
  # by re-deriving the matrix math in the test itself.
  private def marked_map(marks)
    Array.new(32) { Array.new(32, " ") }.tap do |rows|
      marks.each { |(col, row), ch| rows[row][col] = ch }
    end.map(&:join)
  end

  # A checkerboard of 8x8 tiles, sized +size+.
  private def checkerboard_at(size)
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
  private def square_widths(screen, y = 80)
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

  # A checkerboard of two colours, as a whole program.
  private def board_program(scale: nil)
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
    builder.finalize_program
    builder.program
  end

  # A turning background pivots on the middle of the screen unless the game says otherwise.
  # Zoomed 2x about (40, 80), the screen point 160 pixels right of that pivot samples a
  # texture point only 80 right of it — column 15. The same zoom about the middle of the
  # screen samples column 20, which is what test_scale_zooms_in_toward_the_center pins, so
  # the two marks tell a moved pivot from an unmoved one.
  private def a_board_zoomed_about(x, y)
    map = marked_map({ [20, 10] => "#", [15, 10] => "$" })
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      image :red, "#" => :red do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :red
      background(:board, tiles: :t, map: map).turns_around(x, y).scale(2.0)
      game_loop { wait_vblank }
    end
    builder.finalize_program
    builder.program
  end

  ZOOM_SAMPLED = [200, 80].freeze

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
  # Builder#defer_affine_write, registered once a background is made affine at all.
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

  # HOW A TURNING LAYER READS ITS COLOURS, which is not a choice: that pair of hardware
  # layers reads a whole byte per pixel whatever the art is drawn from, because its map
  # holds one byte a cell with no room to name a group of sixteen colours. A board drawn
  # from two colours is the case that catches it — few enough colours to be sorted into
  # such a group, which would store the tiles at half size under a layer reading them at
  # full size: half of every tile blank, every colour after the first black.
  def test_a_turning_background_drawn_from_few_colours_draws_the_same_on_both
    assert_backends_agree(board_program, frames: 4)
  end

  def test_scale_zooms_toward_the_point_it_is_told_to_turn_around
    i = game_player.run(a_board_zoomed_about(40, 80), frames: 4)

    assert_equal Color.resolve(:red), i.screen.pixel(*ZOOM_SAMPLED),
                 "the picture zoomed toward the middle of the screen, not toward the point it was given"
  end

  # Every pixel rather than the one sampled above, and a pivot off both axes so a backend
  # that had swapped or dropped one of the two numbers cannot pass.
  def test_the_two_backends_agree_about_the_point_it_turns_around
    assert_backends_agree(a_board_zoomed_about(40, 120), frames: 4)
  end

  # Nothing about the picture moves when only the pivot does: at its drawn size, upright,
  # a background lands in exactly the same place whatever it is told to turn around. That
  # is what makes this safe to say on a background whose animation has not started.
  def test_an_unturned_picture_lands_in_the_same_place_whatever_it_turns_around
    plain = marked_map({ [20, 10] => "#" })
    picture = lambda do |pivot|
      builder = Builder.new
      builder.instance_eval do
        screen :rotozoom
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        board = background :board, tiles: :t, map: plain
        board.turns_around(*pivot) if pivot
        board.rotate(0)
        game_loop { wait_vblank }
      end
      builder.finalize_program
      game_player.run(builder.program, frames: 4).screen
    end

    # Where the mark is drawn, untouched: column 20 of the map is screen pixels 160..167.
    where_it_was_drawn = [164, 84]

    assert_equal Color.resolve(:white), picture.call([17, 133]).pixel(*where_it_was_drawn),
                 "naming a pivot moved a picture that is not turning"
    assert_equal Color.resolve(:white), picture.call(nil).pixel(*where_it_was_drawn)
  end

  # A pivot named in the MIDDLE of a declaration must not break the line it is in: the
  # size written after it is still the size the picture starts at, which a scene's body
  # would otherwise put back on every frame it runs. Written as a scene because that is
  # the only place the difference shows — the sword flying at the player is exactly this
  # line, and it sticking is what sent this work here in the first place.
  def test_a_pivot_between_the_declaration_and_its_size_leaves_the_size_free_to_ease
    map = marked_map({ [20, 10] => "#" })
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      tiles :t, "#" => :white
      var :state, 0
      scene :title do
        board = background(:board, tiles: :t, map: map).turns_around(40, 80).scale(4.0)
        board.scale.approach! 1.0, 1.0
      end
      game_loop { case_var(:state) { when_val 0, :title } }
    end
    builder.finalize_program
    i = game_player.run(builder.program, frames: 8)

    # Eased back to its drawn size, the mark is where it was drawn: column 20 of the map
    # is screen pixels 160..167. Stuck partway, that pixel samples column 10, which is blank.
    assert_equal Color.resolve(:white), i.screen.pixel(164, 84),
                 "the size never eased back — naming the pivot broke the declaration it sits in"
  end
end

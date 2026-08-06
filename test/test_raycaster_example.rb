# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../examples/raycaster"

# The Raycaster example (examples/raycaster.rb): a first-person view of a maze, built on
# `table` (sine, wall height and the maze itself are build-time ROM tables the rays look
# up) and on `times_fraction` (the player stands between cells, so positions and distances
# carry a fraction). The player stands inside a walled room, so every screen column hits a
# wall and draws a shaded strip through the eye line.
class TestRaycasterExample < Minitest::Test
  # How many screen columns show a wall — any of the three depth shades — at the horizon.
  def wall_columns(sample)
    (0...240).step(8).count { |x| Raycaster::WALL_SHADES.include?(sample.call(x + 3, 80)) }
  end

  # The row where the wall starts in each column: how tall that column's wall is drawn.
  # This is the whole picture reduced to 30 numbers, which is what makes the shape of the
  # view assertable instead of something you have to look at.
  def wall_tops(screen)
    (0...Raycaster::NUM_COLS).map do |col|
      x = (col * Raycaster::COL_W) + (Raycaster::COL_W / 2)
      (0...160).find { |row| screen.pixel(x, row) != Raycaster::SKY } || 160
    end
  end

  def test_it_builds_a_rom
    assert_operator Raycaster.build_rom(out: StringIO.new, err: StringIO.new).size, :>, 0
  end

  def test_walls_render_on_the_interpreter
    interp = Reference.new.run(Raycaster.program, frames: 2)
    assert_operator wall_columns(->(x, y) { interp.screen.pixel(x, y) }), :>=, 20,
                    "the surrounding walls should draw a strip in most columns"
  end

  def test_walls_render_on_the_console
    # One game frame does a lot (a ray per column, a row per wall pixel), so it spans
    # several emulated frames before the first double-buffer flip — give it headroom.
    v = assert_gemba_loads_rom(Raycaster.build_rom(out: StringIO.new, err: StringIO.new), frames: 24)
    assert_operator wall_columns(->(x, y) { v.pixel_gba(x, y) }), :>=, 20,
                    "the surrounding walls should draw a strip in most columns on hardware"
  end

  # The room has a sky above the eye line and a floor below it. Without those the view is
  # walls on black, and nothing reads as a room.
  def test_the_room_has_a_sky_and_a_floor
    screen = Reference.new.run(Raycaster.program, frames: 2).screen

    assert_equal Raycaster::SKY, screen.pixel(120, 2), "the top of the view should be sky"
    assert_equal Raycaster::FLOOR, screen.pixel(120, 158), "the bottom should be floor"
  end

  # A flat wall must draw flat. One ray pointing exactly straight ahead reaches a wall a
  # whole step sooner than its angled neighbours, and no correction afterwards can put
  # that step back — it shows as a single notched column in the middle of the view, at
  # every angle you turn to. The fan is offset so that ray does not exist; this is the
  # test that says so.
  def test_no_column_is_notched_at_any_viewing_angle
    [1, 3, 6, 10, 16, 24, 32, 48].each do |turning_frames|
      interp = Reference.new
      interp.input_each_frame { |frame| frame <= turning_frames ? [:right] : [] }
      tops = wall_tops(interp.run(Raycaster.program, frames: turning_frames + 1).screen)

      notched = (1...tops.length - 1).select do |i|
        tops[i] != tops[i - 1] && tops[i] != tops[i + 1] &&
          (tops[i] - tops[i - 1]).positive? == (tops[i] - tops[i + 1]).positive?
      end

      assert_empty notched,
                   "after #{turning_frames} frames of turning, column(s) #{notched.inspect} " \
                   "stand out from both neighbours: #{tops.inspect}"
    end
  end

  # Walking is what makes it a room you are inside rather than a picture you spin in.
  # Facing east at the start, six frames of walking move exactly six steps along x and not
  # at all along y — which also says the step really is the facing direction and not some
  # fixed vector.
  def test_holding_up_walks_the_player_forward
    start = (3 * Raycaster::FIXED) + (Raycaster::FIXED / 2)
    walked = Reference.new.hold(:up).run(Raycaster.program, frames: 6)

    assert_equal start, Reference.new.run(Raycaster.program, frames: 6)[:px],
                 "the player should stand still with nothing held"
    assert_equal start + (6 * Raycaster::WALK), walked[:px]
    assert_equal start, walked[:py], "walking east should not drift north or south"
  end

  # The maze has a solid wall at cell 5 of the player's row, so walking east must stop in
  # cell 4 rather than pass through it. Held far longer than the 16 steps it takes to get
  # there, so a player who can walk through walls ends up well outside the maze.
  def test_the_player_cannot_walk_through_a_wall
    interp = Reference.new
    interp.input_each_frame { |frame| frame <= 64 ? [:up] : [] }
    walked = interp.run(Raycaster.program, frames: 70)

    assert_equal 4, walked[:px] / Raycaster::FIXED,
                 "the player should come to rest in the cell before the wall"
  end
end

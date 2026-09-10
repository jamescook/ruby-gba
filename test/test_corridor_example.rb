# frozen_string_literal: true

require "test_helper"

require_relative "../examples/corridor"

# The corridor example (examples/corridor.rb): the corpus's witness NEAR THE LINE.
#
# Every other example is comfortable — the heaviest of the rest uses under half a frame — so
# nothing in the corpus was ever close enough to the edge for "does it fit" to be a real
# question. Corridor spends most of a frame, and the tests below are the two halves of that:
# it is a real game that draws a real picture, and it is heavy enough that a change which
# pushed it over would be caught here.
class TestCorridorExample < Minitest::Test
  include RubyGBA::Constants

  # RubyGBA.build runs the guardrails and the ROM-image validation, so a clean build IS
  # the check.
  def test_the_example_builds_clean
    assert_operator Corridor.build_rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # It is a first-person view, so a settled frame shows sky above the eye line, floor below it,
  # and walls in between — and the status bar underneath, which is the part `inside` protects.
  def test_it_draws_a_view_with_a_status_bar_under_it
    i = Reference.new.run(Corridor.program, frames: 4)
    pixels = i.screen.to_a

    assert_includes pixels, Corridor::SKY, "sky above the eye line"
    assert_includes pixels, Corridor::FLOOR, "floor below it"
    assert(Corridor::WALL_SHADES.any? { |c| pixels.include?(c) }, "at least one wall column")
    assert_includes pixels, Corridor::BAR, "the status bar under the view"
  end

  # THE STATUS BAR IS NOT DRAWN OVER. `inside` holds the view to the top 128 rows, so nothing
  # the view draws — not the sky, not the floor, not a wall column tall enough to run past the
  # bottom — reaches the bar. Written as a check on the picture rather than on the clip, since
  # the picture is what an author sees.
  def test_the_view_never_reaches_into_the_bar
    i = Reference.new.run(Corridor.program, frames: 4)
    view_colors = [Corridor::SKY, Corridor::FLOOR, *Corridor::WALL_SHADES]

    (Corridor::VIEW_H...160).each do |y|
      row = (0...240).map { |x| i.screen.pixel(x, y) }
      assert_empty(row & view_colors, "row #{y} is under the view and must hold none of its colors")
    end
  end

  # WHAT THE EXAMPLE IS FOR. It has to stay near the line to be worth having: too light and it
  # is just another comfortable example, too heavy and it does not ship. Measured by running
  # it — this used to ask an estimate the same question, and how close that estimate came was
  # itself most of what this file tested.
  def test_it_is_heavy_and_still_fits
    require_gemba_core!
    spare = idle_share_of(Corridor::GAME)

    assert_operator spare, :<, 0.45, "a witness near the line has to be near it: #{spare}"
    assert_operator spare, :>, 0.0, "...and an example that ships must still fit: #{spare}"
  end

  # THE TEST THIS EXAMPLE EXISTS FOR: the only question an author acts on is whether it fits,
  # and this is the same game either side of the line. Sixty rays holds 60 frames a second;
  # eighty does not. Both are run, so neither answer is anybody's opinion.
  def test_which_side_of_the_line_the_game_is_on
    require_gemba_core!
    [[Corridor::NUM_COLS, Corridor::COL_W, true, "BCOR"],
     [80, 3, false, "BCO8"]].each do |cols, col_w, should_fit, code|
      game = Corridor.game(name: "COR#{cols}", code: code, cols: cols, col_w: col_w)
      result = profile_of(game)

      assert_equal should_fit, !result.dropping_frames?,
                   "#{cols} rays: the console produced #{result.fps} frames a second"
    end
  end

  def profile_of(game)
    rom = game.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
    RubyGBA::Profiler.run(rom, frames: 30, tearing: false)
  end

  def idle_share_of(game) = profile_of(game).idle_share
end

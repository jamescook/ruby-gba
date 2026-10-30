# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/corridor").to_s

# The corridor example (examples/corridor.rb): the corpus's witness NEAR THE LINE.
#
# Every other example is comfortable — the heaviest of the rest uses under half a frame — so
# nothing in the corpus was ever close enough to the edge for "does it fit" to be a real
# question. Corridor spends most of a frame, and the tests below are the two halves of that:
# it is a real game that draws a real picture, and it is heavy enough that a change which
# pushed it over would be caught here. How heavy it is, measured by running the Advance's
# cartridge, is in test/lowering/gba/examples/test_corridor_example_cartridge.rb.
class TestCorridorExample < Minitest::Test

  # VBlank.build runs the guardrails and the ROM-image validation, so a clean build IS
  # the check.
  def test_the_example_builds_clean
    assert_operator Corridor.build_rom(out: nil, err: nil).size, :>, 0, "the built ROM should be non-empty"
  end

  # It is a first-person view, so a settled frame shows sky above the eye line, floor below it,
  # and walls in between — and the status bar underneath, which is the part `inside` protects.
  def test_it_draws_a_view_with_a_status_bar_under_it
    i = game_player.run(Corridor.program, frames: 4)
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
    i = game_player.run(Corridor.program, frames: 4)
    view_colors = [Corridor::SKY, Corridor::FLOOR, *Corridor::WALL_SHADES]

    (Corridor::VIEW_H...160).each do |y|
      row = (0...240).map { |x| i.screen.pixel(x, y) }
      assert_empty(row & view_colors, "row #{y} is under the view and must hold none of its colors")
    end
  end
end

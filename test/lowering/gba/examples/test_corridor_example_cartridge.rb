# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/corridor").to_s

# The corridor example (examples/corridor.rb), the corpus's witness NEAR THE LINE, measured on
# the Advance's own cartridge: how much of a frame it leaves idle, and which side of the line the
# same game is on with more rays. The picture it draws is in
# test/console/gba/examples/test_corridor_example.rb.
class TestCorridorExampleCartridge < Minitest::Test
  # WHAT THE EXAMPLE IS FOR. It has to stay near the line to be worth having: too light and it
  # is just another comfortable example, too heavy and it does not ship. Measured by running
  # it — this used to ask an estimate the same question, and how close that estimate came was
  # itself most of what this file tested.
  def test_it_is_heavy_and_still_fits
    require_emulator!
    spare = idle_share_of(Corridor.default)

    assert_operator spare, :<, 0.45, "a witness near the line has to be near it: #{spare}"
    assert_operator spare, :>, 0.0, "...and an example that ships must still fit: #{spare}"
  end

  # THE TEST THIS EXAMPLE EXISTS FOR: the only question an author acts on is whether it fits,
  # and this is the same game either side of the line. Sixty rays holds 60 frames a second;
  # eighty does not. Both are run, so neither answer is anybody's opinion.
  def test_which_side_of_the_line_the_game_is_on
    require_emulator!
    [[Corridor::NUM_COLS, Corridor::COL_W, true],
     [80, 3, false]].each do |cols, col_w, should_fit|
      game = Corridor.game(name: "COR#{cols}", cols: cols, col_w: col_w)
      result = profile_of(game)

      assert_equal should_fit, !result.dropping_frames?,
                   "#{cols} rays: the console produced #{result.fps} frames a second"
    end
  end

  private def profile_of(game)
    rom = game.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
    VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
  end

  private def idle_share_of(game) = profile_of(game).idle_share
end

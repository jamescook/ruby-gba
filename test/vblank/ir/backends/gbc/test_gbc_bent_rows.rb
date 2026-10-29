# frozen_string_literal: true

require "test_helper"

# A BACKGROUND BENT ROW BY ROW, IN A GAME WHOSE PASS TAKES SEVERAL FRAMES. The Color bends a row by
# moving the background along as the line before it ends, from an interrupt the display raises at
# the end of every line.
#
# A pass that ends late can find the blank begun before it sleeps. The game used to sleep through
# it until the next interrupt, which here is the display's as the frame's first line ends, and
# then copy the picture in while the screen was drawn: the first rows bent wrong, and a line's
# interrupt taken during the sprite table's copy (when the processor can read only its quick
# memory) ran nonsense until the console started again. Where in the frame a pass ends turns on
# how long it takes, so the ripple is played with more or less work in its loop, to end its passes
# at many different moments.
class TestGBCBentRows < Minitest::Test
  FRAMES = 8
  EXTRA_WORK = (0..24)

  def self.ripple(extra)
    VBlank.game("BENT ROWS", consoles: %i[gbc]) do
      screen :tiled
      image :bar, "." => :transparent, "#" => :red do
        (["##......"] * 8).join("\n")
      end
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(20) { "#" * 30 }
      ripple = table :ripple, (0...64).map { |i| (Math.sin(i * 2 * Math::PI / 64) * 3).round }
      phase = var :phase, 0
      spare = var :spare, 0
      water.scroll_each_row { |row| ripple[(row - phase) % 64] }
      game_loop do
        phase.add! 1
        extra.times { spare.add! 1 }
      end
    end
  end

  # What went wrong with +extra+ more work a pass, or nil. A cartridge that started again never
  # ends the pass the run waits for, which the checked run cannot answer; one whose copies ran as
  # the screen was drawn shows rows bent wrong.
  def self.wrong_with(extra)
    VBlank::IR::Backends::GBC::CheckedRun.new.run(ripple(extra).program(console: :gbc), frames: FRAMES)
    nil
  rescue VBlank::IR::Backends::RunComparison::Disagreement, VBlank::IR::Backends::GBC::HeadlessRun::CannotAnswer => e
    "#{extra}: #{e.message}"
  end

  def test_late_passes_bend_rows_as_the_interpreter_does
    wrong = EXTRA_WORK.filter_map { |extra| self.class.wrong_with(extra) }
    assert_empty wrong, "with this much more work a pass, the cartridge went wrong"
  end
end

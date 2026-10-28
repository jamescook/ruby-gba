# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/chip_band").to_s

# examples/chip_band.rb built for the desktop shows the interpreter's picture and logs its sound,
# frame by frame, while the cursor moves down the list of tunes and each one plays a while: the
# menu redrawn, and every tune's notes — held, faded, slid, wobbled, spread across the speakers
# and shimmering — set on their voices as the interpreter sets them.
class TestChipBandPicture < Minitest::Test
  include NativeComparison

  # DOWN pressed every forty frames, held for three, through the six tunes.
  PRESSES = Ractor.make_shareable(
    NativeComparison.held_for([40..42, :down], [80..82, :down], [120..122, :down], [160..162, :down],
                              [200..202, :down])
  )

  def test_chip_band_matches_the_interpreter_through_every_tune
    program = Native.new.checked_program(ChipBand::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 260, buttons: PRESSES
  end
end

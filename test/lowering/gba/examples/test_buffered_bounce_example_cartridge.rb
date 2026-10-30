# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/buffered_bounce").to_s

# The buffered-bounce example (examples/buffered_bounce.rb) on the Advance's cartridge, read in
# the emulator. That it builds clean and draws its balls is in
# test/console/gba/examples/test_buffered_bounce_example.rb.
class TestBufferedBounceExampleCartridge < Minitest::Test
  include VBlank::Console::Hardware

  BALL_COLORS = %i[yellow cyan magenta].freeze

  # On the console: the emulator boots the ROM, resolves Mode 4 indices through the auto
  # palette, and presents the flipped page. The blue field and at least one ball
  # must render — not a black screen.
  def test_it_renders_on_the_console
    v = assert_emulator_loads_rom(BufferedBounce.build_rom, frames: 6)
    assert on_screen?(v, :blue), "the blue field should render on the console"
    assert BALL_COLORS.any? { |c| on_screen?(v, c) },
           "at least one ball should render on the console"
  end

  private

  # True if any pixel on a coarse grid is the given color. An 8x8 ball on even
  # columns always straddles the 4-pixel grid, so a drawn ball is never missed.
  def on_screen?(verifier, color)
    want = Color.resolve(color)
    (0...SCREEN_WIDTH).step(4).any? do |x|
      (0...SCREEN_HEIGHT).step(4).any? { |y| verifier.pixel_gba(x, y) == want }
    end
  end
end

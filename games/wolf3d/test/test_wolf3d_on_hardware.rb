# frozen_string_literal: true

require_relative "test_helper"

# The same claims on the real cartridge. Reached through RubyGBA::Verifier rather than the
# framework's own test support, because a game outside the framework cannot reach into its test
# directory — and this one is here to feel that constraint.
class TestWolf3DOnHardware < Minitest::Test
  include Wolf3DTest

  def setup
    @rom = Wolf3D.build_rom(out: StringIO.new, err: StringIO.new)
  end

  def test_the_cartridge_boots_and_draws_its_lettering
    gba = RubyGBA::Verifier.new(@rom, frames: 4)

    refute gba.all_black?, "the cartridge booted to a black screen"
    assert_operator lit_pixels(gba, 40, 80), :>, 100, "expected the title lettering"
  end

  def test_the_prompt_blinks_on_the_console
    showing = lit_pixels(RubyGBA::Verifier.new(@rom, frames: 4), 100, 112)
    gone = lit_pixels(RubyGBA::Verifier.new(@rom, frames: 70), 100, 112)

    assert_operator showing, :>, 0, "expected the prompt early in the cycle"
    assert_equal 0, gone, "expected the prompt to be dark later in the cycle"
  end

  private

  def lit_pixels(gba, top, bottom)
    backdrop = gba.pixel_gba(0, 0)
    (0...240).sum { |x| (top...bottom).count { |y| gba.pixel_gba(x, y) != backdrop } }
  end
end

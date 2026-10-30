# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/buffered_bounce").to_s

# The buffered-bounce example (examples/buffered_bounce.rb): the worked demo that
# the tear-proof double-buffered screen is usable today with the fill/clear verbs.
# It clears and repaints the whole screen every frame — the pattern that tears a
# direct-color game — and stays clean because it's buffered. We prove it builds
# clean (which runs the guardrails and ROM-image checks) and actually renders its
# balls on a blue field, on both backends, so it can't rot into a black screen. The
# Advance's cartridge read in the emulator is in
# test/lowering/gba/examples/test_buffered_bounce_example_cartridge.rb.
class TestBufferedBounceExample < Minitest::Test

  BALL_COLORS = %i[yellow cyan magenta].freeze

  # VBlank.build runs the guardrails (raising on any fatal footgun) and the
  # ROM-image validation, so a clean build IS the check.
  def test_the_example_builds_clean
    rom = BufferedBounce.build_rom
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # On the reference interpreter, a settled frame shows the blue field and all
  # three balls — the promise that buffered drawing lands the same pixels.
  def test_it_renders_the_balls_on_a_blue_field
    i = game_player.run(BufferedBounce.program)
    assert i.buffered, "the demo opts into double buffering"

    pixels = i.screen.to_a
    assert_includes pixels, Color.resolve(:blue), "the blue field should fill the screen"
    BALL_COLORS.each do |c|
      assert_includes pixels, Color.resolve(c), "the #{c} ball should be drawn"
    end
  end

end

# frozen_string_literal: true

require "test_helper"
require "differential"

# The test of test_tint.rb about how the Advance's display mixes a tint: at eight bits a channel.
# A Game Boy Color walks the colours of its lists instead, at five bits, so this plays on the
# Advance's runs alone.
class TestTintOnTheAdvance < Minitest::Test
  include Differential

  # A screen cleared to +under+ and one tint, as the DSL writes it.
  private def tinted(color, amount, under:)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen under
      tint color, amount
      halt
    end
    b.finalize_program
    b.program
  end

  private def shown(program) = game_player.run(program).screen.pixel(120, 80)

  # A gray of 16 in every channel tinted half way to yellow. The display mixes at eight
  # bits a channel, which makes red and green 24; mixed at five bits they would be 23, a
  # step darker. Blue goes half way to nothing, 8 either way.
  MID_GRAY = 16 | (16 << 5) | (16 << 10)

  def test_a_tint_mixes_at_eight_bits_as_the_console_does
    program = tinted(:yellow, 50, under: MID_GRAY)

    assert_backends_agree(program, frames: 2)
    assert_equal 24 | (24 << 5) | (8 << 10), shown(program)
  end
end

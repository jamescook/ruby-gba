# frozen_string_literal: true

require "test_helper"
require "differential"

# The test of test_sprite_upside_down.rb whose picture is more pieces than the 40 a Game Boy
# Color shows at once, which its hardware cannot, so it plays on the Advance's runs alone.
class TestSpriteUpsideDownOnTheAdvance < Minitest::Test
  include Differential

  INK = RubyGBA::Graphics::Color.rgb(31, 20, 0)
  EDGE = RubyGBA::Graphics::Color.rgb(0, 31, 10)
  CLEAR = RubyGBA::Graphics::Color.rgb(0, 0, 1)

  # A picture bigger than the console draws is cut into pieces, and each piece's place must be
  # reflected within the whole picture, not within its own box.
  def test_a_big_picture_turned_upside_down_draws_the_same_on_both_backends
    wide = 96
    tall = 48
    data = (0...(wide * tall)).map do |i|
      x = i % wide
      y = i / wide
      next CLEAR unless y < 30 && x < 70

      x < 8 || y < 8 ? EDGE : INK
    end
    clear = CLEAR
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :cruiser, width: wide, height: tall, data: data, transparent: clear
      sprite :hero, at: [40, 30], frames: [:cruiser, upside_down(:cruiser)], rate: 3
      game_loop {}
    end
    builder.finalize_program

    [12, 15].each { |frames| assert_backends_agree(builder.program, frames: frames) }
  end
end

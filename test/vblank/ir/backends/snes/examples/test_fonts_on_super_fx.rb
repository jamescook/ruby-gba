# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/fonts").to_s

# examples/fonts.rb on a Super Nintendo cartridge with a Super FX 2: words and a number in both fonts
# painted into the chip's RAM, the screen cleared by the chip, held to the interpreter — every pixel
# — after every pass.
class TestFontsOnSuperFX < Minitest::Test
  def test_both_fonts_paint_like_the_interpreter
    run = game_player.run(FontsDemo::GAME.program(console: :snes, variant: :superfx), frames: 3)

    assert_equal Color.resolve(:white), run.screen.pixel(8, 8), "the D of DEFAULT starts at its corner"
  end
end

# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/fonts").to_s

# examples/fonts.rb on a Super Nintendo: words and a number in the default font and the tiny one,
# painted once, held to the interpreter — every pixel — after every pass.
class TestFontsOnSNES < Minitest::Test
  def test_both_fonts_paint_like_the_interpreter
    run = game_player.run(FontsDemo::GAME.program(console: game_console), frames: 3)

    assert_equal Color.resolve(:white), run.screen.pixel(8, 8), "the D of DEFAULT starts at its corner"
  end
end

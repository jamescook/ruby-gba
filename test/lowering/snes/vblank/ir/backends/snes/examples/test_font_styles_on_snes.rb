# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/font_styles").to_s

# examples/font_styles.rb on a Super Nintendo: the built-in font and two the game draws itself,
# held to the interpreter — every pixel — after every pass.
class TestFontStylesOnSNES < Minitest::Test
  def test_the_games_own_fonts_paint_like_the_interpreter
    run = game_player.run(FontStyles::GAME.program(console: game_console), frames: 3)

    assert_equal Color.resolve(:green), run.screen.pixel(8, 40), "the lowercase h's top-left"
  end
end

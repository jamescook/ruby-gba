# frozen_string_literal: true

require "test_helper"
require "differential"

require "stringio"

# A game that never says `screen` draws on a bitmap screen, as if its first line were
# `screen :bitmap`. The interpreter always drew such a game; the cartridge has to switch that
# screen on at boot too, or the console shows nothing but its backdrop colour.
class TestScreenDefault < Minitest::Test
  include Differential

  private def program(&body)
    b = VBlank::Builder.new
    b.instance_eval(&body)
    b.finalize_program
    b.program
  end

  private def red_dot_with_no_screen
    program do
      game_loop do
        pixel 10, 10, :red
      end
    end
  end

  def test_a_game_with_no_screen_line_draws
    player = game_player.run(red_dot_with_no_screen, frames: 4)
    assert_equal Color.resolve(:red), player.screen.pixel(10, 10)
  end

  def test_a_game_with_no_screen_line_draws_the_same_on_every_lowering
    assert_backends_agree(red_dot_with_no_screen, frames: 4)
  end

  def test_a_game_with_no_screen_line_builds
    rom = VBlank.build("NOSCREEN", console: :gba, out: StringIO.new, err: StringIO.new) do
      game_loop do
        pixel 10, 10, :red
      end
    end
    assert_operator rom.size, :>=, 512
  end
end

# frozen_string_literal: true

require "test_helper"

# The tests of test_fade.rb about how the Advance's display fades: at eight bits a channel, which
# rounds a share the other way for some channels. A Game Boy Color walks the colours of its lists
# instead, at five bits, so these play on the Advance's runs alone.
class TestFadeOnTheAdvance < Minitest::Test
  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A blue screen with a red block at (100, 70), under a fade.
  private def faded(toward, amount)
    program do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 70, 40, 20, :red
      fade toward, amount
      halt
    end
  end

  private def channels(color)
    [color & 0x1F, (color >> 5) & 0x1F, (color >> 10) & 0x1F]
  end

  # A wall of one colour filling the screen, faded toward +toward+ by +amount+ every frame.
  private def a_wall_faded(color, toward, amount)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:brick, "#" => color) { tile }
      tiles :wall, "#" => :brick
      background :wall, tiles: :wall, map: Array.new(20) { "#" * 30 }
      game_loop { fade toward, amount }
    end
  end

  # Halfway on each channel, in both directions. A fade MOVES a channel by a share and
  # rounds the share, whichever way it is going: toward black red loses half of what it
  # has, and half of 31 is 15.5, of which it loses 15 and keeps 16. Toward white it gains
  # half of the headroom it has left. They are not mirror images — one lands on 16 where
  # the other lands on 15 — because the part that rounds is the part that MOVES.
  #
  # Blue on its way to black lands on 15, not red's 16, and that is the emulator the
  # picture is checked against: it works a fade out at eight bits a channel, and for the
  # two channels kept above red the share it takes rounds the other way (see
  # Framebuffer#darkened_by_display).
  def test_a_half_fade_moves_each_channel_half_way
    dark = game_player.run(faded(:black, 50))
    light = game_player.run(faded(:white, 50))

    assert_equal [16, 0, 0], channels(dark.screen.pixel(120, 80)), "red, half faded to black"
    assert_equal [0, 0, 15], channels(dark.screen.pixel(10, 10)), "blue, half faded to black"
    assert_equal [31, 15, 15], channels(light.screen.pixel(120, 80)), "red, half faded to white"
  end

  # One answer written out: white three quarters of the way to black is red 8, green 7,
  # blue 7, which is what the console was measured showing. Five bits a channel would say
  # 8, 8, 8.
  def test_white_three_quarters_to_black_is_eight_seven_seven
    i = game_player.run(a_wall_faded(:white, :black, 75), frames: 2)

    assert_equal [8, 7, 7], channels(i.screen.pixel(8, 8))
  end
end

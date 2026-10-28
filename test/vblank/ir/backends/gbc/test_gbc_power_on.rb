# frozen_string_literal: true

require "test_helper"

# WHAT A COLOR CARTRIDGE SHOWS FROM POWER-ON UNTIL THE GAME'S FIRST FRAME. The cartridge copies its
# art into the console before the game's first line, and a game sets itself up before its first
# frame, which together can take several frames. A Color game whose screens fade in from white
# never shows black on the way: the screen shows the backdrop, the first colour of its first list,
# from power-on until the game draws. A game whose backdrop is black shows black, as it always did.
class TestGBCPowerOn < Minitest::Test
  # A tile of each number, drawn by place from a list whose first colour is white: none of the
  # screen is ever black, so a black pixel is the console showing nothing.
  TILES = 300
  LIST = %i[transparent white red green blue].freeze

  private def white_game_with_much_art(setting_up:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      colors :pale, LIST
      names = (0...TILES).map do |n|
        image :"tile#{n}", width: 8, height: 8, colors: :pale,
                           places: Array.new(64) { |i| (n[i % 9] + n[(i + 3) % 9] + (i / 32)) % 4 + 1 }
        :"tile#{n}"
      end
      keys = (0...TILES).map { |n| (n + 256).chr(Encoding::UTF_8) }
      tiles :set, keys.zip(names).to_h
      field = background :field, tiles: :set, map: Array.new(18) { |r| (0...20).map { |c| keys[((r * 20) + c) % TILES] }.join }
      # Drawn with lists of its own, as a screen faded in from white is: its first colour, white,
      # is then the backdrop, since no cell of it is empty.
      colors :pale_again, %i[transparent white blue green red]
      count = var :count, 0
      repeat(setting_up) { count.add! 1 }
      game_loop { field.draw_with :pale_again }
    end
    b.finalize_program
    b.program
  end

  # Sixteen places across the screen.
  SPOTS = [20, 60, 100, 140].product([16, 56, 96, 136]).freeze

  def test_a_white_game_never_shows_black_while_it_loads
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(white_game_with_much_art(setting_up: 20_000), title: "WHITE")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0)
    black = (1..30).filter_map do |frame|
      v.step
      frame if SPOTS.any? { |x, y| v.pixel_gba(x, y).zero? }
    end

    assert_empty black, "frames that showed black"
  end
end

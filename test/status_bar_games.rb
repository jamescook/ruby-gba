# frozen_string_literal: true

require "test_helper"

# Small games with a status bar, shared by the tests of the `status_bar` verb
# (test/vblank/builder/test_status_bar.rb) and of its handle (test/vblank/dsl/test_status_bar.rb).
# Every game is laid out from the size of the console the run plays it on, so it plays on the
# Advance and on the Color alike.
module StatusBarGames
  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLACK = VBlank::Graphics::Color.resolve(:black)

  # How tall a bar's picture is in these games: two rows of tiles.
  BAR_HEIGHT = 16

  private

  # A program built for this run's console, so its `screen_height` is that console's.
  def program(&block)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A field of red tiles with a blue row every fourth row, scrolled down a pixel a pass, and a
  # green bar two rows tall whose top is at the bottom of the screen less +from_bottom+. The game
  # loop's body is handed the bar and a counter of the passes.
  def bar_game(from_bottom: BAR_HEIGHT, &body)
    program do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:blue_art, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      tiles :field_tiles, "#" => :red_art, "o" => :blue_art
      tiles :bar_tiles, "#" => :green_art, "o" => :blue_art
      field = background :field, tiles: :field_tiles,
                                 map: Array.new(32) { |r| ((r % 4).zero? ? "o" : "#") * 32 }
      bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - from_bottom
      step = var :step, 0
      game_loop do
        field.scroll_by 0, 1
        instance_exec(bar, step, &body) if body
        step.add! 1
      end
    end
  end

  def screen_height = VBlank::Console.described(game_console).screen_height

  def picture(prog, frames) = game_player.run(prog, frames: frames).screen
end

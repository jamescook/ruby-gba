# frozen_string_literal: true

# SMALL TILED GAMES FOR `screen ... backdrop:`, shared by test/vblank/builder/test_screen_backdrop.rb
# and its twin for what only the Advance does, test/advance/vblank/builder/
# test_screen_backdrop_on_the_advance.rb.
module ScreenBackdropGames
  SKY = VBlank::Graphics::Color.rgb(8, 16, 31)

  module_function

  # One 8×8 tile, red but for its left half, which is see-through, in the tileset :corner_set.
  def declare_corner_tile(game)
    game.image :corner, width: 8, height: 8, "#" => :red, "." => :transparent do
      8.times.map { "....####" }.join("\n")
    end
    game.tiles :corner_set, "c" => :corner
  end

  # A title that says the screen line +title_screen+ gives it (a Hash of `screen :tiled` options,
  # nil for none), shown for five frames, then a board that says no screen of its own; each the
  # corner tile in its top left cell alone.
  def title_and_board(title_screen: nil)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      ScreenBackdropGames.declare_corner_tile(self)
      state = var :state, 0
      tick = var :tick, 0
      scene(:title) do
        screen(:tiled, **title_screen) if title_screen
        background :title, tiles: :corner_set, map: ["c"]
      end
      scene(:board) { background :board, tiles: :corner_set, map: ["c"] }
      game_loop do
        tick.add! 1
        (tick == 6).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :title
          when_val 1, :board
        end
      end
    end
    b.finalize_program
    b.program
  end
end

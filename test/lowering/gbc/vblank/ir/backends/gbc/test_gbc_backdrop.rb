# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# THE COLOR KEEPS ONE BACKDROP FOR THE GAME. It has no single backdrop colour: each of its
# background colour lists keeps its own first colour, which the see-through pixels of the tiles drawn
# from it show, and an empty cell shows the first list's. So the game's backdrop is built into every
# list, and a scene that says another is refused, saying what to do.
class TestGBCBackdrop < Minitest::Test
  def test_a_scene_with_a_backdrop_of_its_own_is_refused
    program = ScreenBackdropGames.title_and_board(title_screen: { backdrop: ScreenBackdropGames::SKY })
    error = assert_raises(VBlank::IR::Backends::GBC::LoweringError) do
      VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "BACKDROP")
    end

    assert_match(/:title/, error.message)
    assert_match(/game's own `screen`/, error.message)
  end
end

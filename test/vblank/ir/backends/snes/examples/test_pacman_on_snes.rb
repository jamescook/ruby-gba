# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/pacman").to_s

# examples/pacman.rb on a Super Nintendo, laid out on its 256×224 screen: Pac-Man walks up to the
# pellet above him and eats it, then stands still until the ghost catches him, and flashes white
# while he is stunned — a sprite drawn with another list of colours. Held to the interpreter,
# picture, sprites and sounds, after every pass.
class TestPacmanOnSNES < Minitest::Test
  def test_pacman_eats_a_pellet_and_flashes_when_caught_like_the_interpreter
    run = game_player.input_each_frame { |frame| frame <= 40 ? [:up] : [] }
    run.run(Pacman::GAME.program(console: game_console), frames: 200)

    assert_operator run[:eaten], :>=, 1, "he ate the pellet above him"
    assert_operator run[:caught], :>=, 1, "the ghost caught him"
  end
end

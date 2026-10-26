# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/pacman").to_s

# examples/pacman.rb built for the Game Boy Color, held to the interpreter after every pass of a
# recorded run: Pac walked about the smaller room, a pellet eaten, the ghost catching him and him
# blinking white.
class TestPacmanOnGBC < Minitest::Test
  RUN = { 2..30 => [:up], 31..60 => [:left], 61..75 => [:down], 76..90 => [:right] }.freeze

  def test_pacman_matches_the_interpreter_through_a_recorded_run
    run = game_player.input_each_frame { |frame| RUN.find { |frames, _| frames.cover?(frame) }&.last || [] }
    run.run(Pacman::GAME.program(console: :gbc), frames: 260)

    assert_operator run[:eaten], :>=, 1, "the run should eat a pellet"
    assert_operator run[:caught], :>=, 1, "and the ghost should catch him once he stands still"
  end
end

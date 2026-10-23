# frozen_string_literal: true

require "test_helper"
require RubyGBA.root.join("examples/pong").to_s

# examples/pong.rb built for the Game Boy Color: a cartridge that boots and plays in the emulator,
# held to the interpreter — every variable and every pixel — after every pass of recorded runs.
# Its title turns on the Advance and is shown unturned on the Color, by both.
class TestPongOnGBC < Minitest::Test
  # START on the title, the zoom into play, and the player's paddle up and down a while.
  def test_a_game_of_pong_matches_the_interpreter
    run = game_player.input_each_frame { |frame| frame < 3 ? [:a] : (frame / 30).odd? ? [:up] : [:down] }
    run.run(Pong.program(console: :gbc), frames: 300)

    assert_equal 1, run[:state], "the game should be under way"
    assert_operator run[:player_score] + run[:cpu_score], :>=, 1, "and a point scored"
  end

  # Down to the LEVEL row, into the difficulty screen — a painted one — and NORMAL picked there.
  # A pass takes more than one frame on the Color in places — the title's second, every pass of
  # the painted difficulty screen — and the buttons are read on every frame, so each button is held
  # for six frames, a whole pass however long it takes, and let go for twelve; and the first waits
  # until the title's menu is up.
  def test_the_difficulty_screen_matches_the_interpreter
    presses = %i[down down a up a].each_with_index.flat_map do |button, n|
      (0...6).map { |held| [8 + (n * 18) + held, [button]] }
    end.to_h
    run = game_player.input_each_frame { |frame| presses.fetch(frame, []) }
    run.run(Pong.program(console: :gbc), frames: 110)

    assert_equal 0, run[:state], "back on the title"
    assert_equal (CPU_NORMAL * 65_536).to_i, run[:cpu_speed], "with NORMAL picked"
  end
end

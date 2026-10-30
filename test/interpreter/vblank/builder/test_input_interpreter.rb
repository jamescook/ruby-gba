# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_input"

# A SLOW GAME'S PRESSES IN THE INTERPRETER, told that each pass takes two frames — which only the
# interpreter can be told. The buttons as every run plays them are in
# test/all/vblank/builder/test_input.rb.
class TestInputInterpreter < Minitest::Test
  include InputGames

  # A press is never lost to a slow game (InputGames#slow_game_counting_presses).
  def test_a_slow_game_counts_every_tap_once_in_the_interpreter
    TAPPED.each do |what, down|
      oracle = VBlank::IR::Backends::Reference.new
                                               .frames_each_pass { 2 }
                                               .input_each_frame { |frame| down.include?(frame) ? [:a] : [] }
                                               .run(slow_game_counting_presses, frames: 20)

      assert_equal 1, oracle[:presses], "A held #{what}"
    end
  end
end

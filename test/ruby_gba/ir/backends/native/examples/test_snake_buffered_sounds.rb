# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "sound_comparison"
require RubyGBA.root.join("examples/snake_buffered").to_s

# examples/snake_buffered.rb built for the desktop sounds like the cartridge: started and then
# left alone, the snake runs straight into a wall, and the beep as it dies — on the second square
# voice — is compared with the emulator frame by frame (see SoundComparison). The game has no
# song, so the first voice is not asked about.
class TestSnakeBufferedSounds < Minitest::Test
  include SoundComparison

  GAME_OVER = 2

  # START held for a few frames, since the console is a frame or two behind the desktop build;
  # everything after is counted from the press, so the two play the same game.
  START = Ractor.make_shareable(NativeComparison.held_for([3..8, :start]))

  def test_the_beep_as_the_snake_dies
    program = Native.new.checked_program(BufferedSnake::GAME, err: nil)
    played = Native::HeadlessRun.new.input_each_frame { |frame| START.fetch(frame, []) }.run(program, frames: 240)

    assert_equal GAME_OVER, played[:state], "the snake should have died in the run compared"
    assert_native_sounds_like_the_console program, frames: 240, buttons: START, voices: [:square2]
  end
end

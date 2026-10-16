# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/jukebox").to_s

# examples/jukebox.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, and plays the same sound: the cursor walks down to the piano tune, which fades the
# first tune out and the chords in, and both sound effects are asked for over the chords — one
# ranked above the tune and one below it.
class TestJukeboxPicture < Minitest::Test
  include NativeComparison

  FRAMES = 240

  # DOWN three times to the piano tune, then A and B together once its chords are sounding, and
  # A again a little later.
  BUTTONS = { 3 => [:down], 6 => [:down], 9 => [:down], 120 => %i[a b], 160 => [:a] }.freeze

  def test_jukebox_matches_the_interpreter_while_effects_play_over_the_chords
    program = Native.new.checked_program(Jukebox::GAME, err: nil)
    played = CheckedPlayer.new.input_each_frame { |frame| BUTTONS.fetch(frame, []) }.run(program, frames: FRAMES)

    assert_includes played.audio, [:sound_effect, :"sfx.hooray"]
    assert_includes played.audio, [:sound_effect, :"sfx.blip"]
    assert(played.mixed_sound.any? { |slice| slice.any?(&:nonzero?) }, "the tunes should be heard")
  end
end

# frozen_string_literal: true

require "test_helper"

# The tests of test_direct_sound.rb whose games play a recording, which a Game Boy Color's
# hardware cannot do, so they play on the Advance's runs alone.
class TestDirectSoundOnTheAdvance < Minitest::Test
  def test_stop_registers_too
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      s = sample :s, pcm: [10, -10], rate: 8000
      s.play
      s.stop
      halt
    end
    log = game_player.run(b.program).audio
    assert_equal [[:sample, :s], [:stop_sample]], log
  end

  def test_playing_an_undefined_sample_is_a_friendly_error
    b = Builder.new
    b.instance_eval { screen :bitmap; RubyGBA::DSL::Sample.new(self, :ghost).play; halt }
    err = assert_raises(Reference::ProgramError) { game_player.run(b.program) }
    assert_match(/ghost/, err.message)
  end
end

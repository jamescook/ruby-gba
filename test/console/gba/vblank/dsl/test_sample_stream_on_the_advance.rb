# frozen_string_literal: true

require "test_helper"

# Streaming a long clip: a PCM clip longer than the old 65536-sample hardware limit used to
# be a hard error. Now any length just plays — the mixer reads one frame's worth of the clip
# out of the cartridge each frame and advances its play position, so a minutes-long track
# loops as background music with no special handling.
#
# This test loops a recording, and reads it far faster than it was recorded so it comes round
# within a few frames. A Game Boy Color cannot loop a recording, and a Super Nintendo cannot read
# one more than four times faster than it was made, so this plays on the Advance's runs alone.
# The clip lowered to the Advance's cartridge and heard in the emulator is in
# test/lowering/gba/vblank/dsl/test_sample_stream_cartridge.rb.
class TestSampleStreamOnTheAdvance < Minitest::Test
  OLD_LIMIT = 65_536 # the sample count that used to be the hard ceiling

  def test_a_long_looping_clip_still_loops_on_the_interpreter
    b = Builder.new
    clip = [40, -40] * ((OLD_LIMIT / 2) + 40) # ~65616 samples — well past the old limit
    b.instance_eval do
      screen :bitmap
      music = sample :music, pcm: clip, rate: 200_000 # fast rate so it loops within a few frames
      music.play(loop: true)
      game_loop { wait_vblank }
    end
    i = game_player.run(b.program, max_steps: 20_000)
    plays = i.audio.count { |e| e == [:sample, :music] }
    assert_operator plays, :>, 1, "a clip past the old limit loops just like a short one (#{plays} plays)"
  end
end

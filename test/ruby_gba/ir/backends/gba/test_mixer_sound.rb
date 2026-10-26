# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "zlib"

# WHAT THE MIX ROUTINE PLAYS, pinned to the byte.
#
# The routine's inner loop mixes more than one sample each time round (see
# Mixer::SAMPLES_A_PASS), and each copy of its body has a jump of its own for a recording
# reaching its end — back to where it holds from, or out when it plays once. A copy that came
# back to the wrong place would play a sound that is nearly right, which no test of "is there
# sound" would ever notice.
#
# So this plays a game that exercises every one of those paths for 120 frames — five looping
# clips of different lengths, a one-shot ending part way through a pass, a pitched one, and a
# shaped chord — and compares a checksum of every byte the console played. The number was
# taken from the routine mixing ONE sample each time round, which is the form whose sound was
# right before it changed. A deliberate change to what the mix plays takes the number again.
class TestMixerSound < Minitest::Test
  PLAYED = 0x5C0E1079

  private def rom
    RubyGBA.build("MIXSAME", console: :gba, out: nil, err: nil) do
      screen :bitmap
      enable_sound
      loops = Array.new(5) do |n|
        sample :"loop#{n}", pcm: Array.new(3001 + (n * 17)) { |i| ((i * (n + 3)) % 200) - 100 }, rate: 8000
      end
      shot = sample :shot, pcm: Array.new(777) { |i| ((i * 7) % 250) - 125 }, rate: 11_025
      piano = instrument :piano, pcm: Array.new(2500) { |i| ((i * 5) % 180) - 90 }, rate: 8000,
                                 envelope: { release: 0.3 }
      frame = var :frame, 0
      game_loop do
        frame.add! 1
        (frame == 2).then { loops.each { |clip| clip.play(loop: true) } }
        (frame % 9 == 0).then { shot.play(pitch: :E4) }
        (frame % 20 == 3).then { piano.play(:C4, :E4, :G4) }
      end
    end
  end

  def test_the_console_plays_the_same_sound_byte_for_byte
    require_emulator!
    played = Dir.mktmpdir("mixer-sound") do |dir|
      path = File.join(dir, "mix.gba")
      rom.write(path)
      probe = RubyGBA::Diagnostics::Emulator.probe(path)
      probe.step(120)
      sound = probe.audio_buffer
      probe.close
      sound
    end

    assert_operator played.bytesize, :>, 0
    assert_equal format("0x%08X", PLAYED), format("0x%08X", Zlib.crc32(played))
  end
end

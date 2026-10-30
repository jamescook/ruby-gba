# frozen_string_literal: true

require "test_helper"

# Streaming a long clip on the Advance's cartridge: a clip past the old 65536-sample limit lowers
# with no error, and plays real sound in the emulator. The same clip looping on every run that
# plays the Advance is in test/console/gba/vblank/dsl/test_sample_stream_on_the_advance.rb.
class TestSampleStreamCartridge < Minitest::Test
  def test_a_long_clip_lowers_without_the_old_length_error
    b = Builder.new
    clip = [0, 40, 0, -40] * 20_000 # 80000 samples
    b.instance_eval do
      screen :bitmap
      long = sample :long, pcm: clip, rate: 8000
      long.play(loop: true)
      game_loop { wait_vblank }
    end
    assert GBA.new.lower(b.program).bytesize.positive?, "a long looping clip lowers to a ROM, no error"
  end

  def test_a_long_streamed_clip_plays_real_audio_on_the_console
    b = Builder.new
    wave = ([90] * 4 + [-90] * 4) * 9_000 # 72000 samples, past the old limit
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      music = sample :music, pcm: wave, rate: 16_000
      music.play(loop: true)
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = ROM.assemble(GBA.new.lower(b.program), title: "STRM", code: "BSTR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)
    assert v.sound?, "a long streamed clip should play real audio (energy #{v.audio_energy})"
  end
end

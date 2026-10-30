# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_wav_import"

# A sample imported from a .wav file, on the Advance's cartridge: its speaker heard in the
# emulator. The decoder and the DSL path on every run are in test/all/vblank/audio/test_wav_import.rb.
class TestWavImportCartridge < Minitest::Test
  include WavFiles

  def test_a_wav_sample_plays_real_audio_on_the_console
    tone = ([200] * 4 + [56] * 4) * 250 # a square wave as unsigned 8-bit
    with_wav(wav_bytes(samples: tone, rate: 8000)) do |path|
      b = Builder.new
      wav_path = path
      b.instance_eval do
        screen :bitmap
        clear_screen :black
        sound = sample :tone, from: wav_path
        sound.play
        game_loop { wait_vblank }
      end
      b.finalize_program
      rom = ROM.assemble(GBA.new.lower(b.program), title: "WAV0", code: "BWAV", maker: "01")
      v = assert_emulator_loads_rom(rom, frames: 6)
      assert v.sound?, "a WAV-loaded sample should play real audio (energy #{v.audio_energy})"
    end
  end
end

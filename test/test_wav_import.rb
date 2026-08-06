# frozen_string_literal: true

require "test_helper"

require "tempfile"

# Importing a .wav file into a playable sample: `sample :name, from: "clip.wav"` reads a
# RIFF/PCM WAV and converts it — 8- or 16-bit, mono or stereo — down to the 8-bit signed
# mono PCM the sampled-audio hardware plays, keeping the file's own rate. The decoder is
# unit-tested; the DSL path is pinned on the interpreter and gemba.
class TestWavImport < Minitest::Test

  Wav = RubyGBA::Wav

  # Build a minimal valid WAV byte string. +samples+ are raw per-channel values (unsigned
  # for 8-bit, signed for 16-bit), interleaved for stereo.
  def wav_bytes(samples:, rate:, bits: 8, channels: 1)
    data = bits == 8 ? samples.pack("C*") : samples.pack("s<*")
    fmt = [1, channels, rate, rate * channels * (bits / 8), channels * (bits / 8), bits].pack("vvVVvv")
    chunks = "fmt " + [fmt.bytesize].pack("V") + fmt + "data" + [data.bytesize].pack("V") + data
    "RIFF" + [4 + chunks.bytesize].pack("V") + "WAVE" + chunks
  end

  # --- the decoder ---

  def test_reads_8bit_mono_recentering_to_signed
    got = Wav.parse(wav_bytes(samples: [128, 200, 128, 56], rate: 11_025))
    assert_equal 11_025, got[:rate]
    assert_equal [0, 72, 0, -72], got[:bytes].unpack("c*"), "unsigned 8-bit is recentered to signed"
  end

  def test_reads_16bit_mono_keeping_the_high_byte
    got = Wav.parse(wav_bytes(samples: [0, 25_600, 0, -25_600], rate: 22_050, bits: 16))
    assert_equal 22_050, got[:rate]
    assert_equal [0, 100, 0, -100], got[:bytes].unpack("c*")
  end

  def test_downmixes_stereo_to_mono
    # two stereo frames (L,R),(L,R): (128,128) -> 0, (200,56) -> (72 + -72)/2 = 0
    got = Wav.parse(wav_bytes(samples: [128, 128, 200, 56], rate: 8000, channels: 2))
    assert_equal [0, 0], got[:bytes].unpack("c*"), "the two channels are averaged to one"
  end

  def test_rejects_a_non_wav_file
    err = assert_raises(Wav::Error) { Wav.parse("not a wav at all........") }
    assert_match(/WAV/i, err.message)
  end

  def test_rejects_compressed_pcm
    riff = wav_bytes(samples: [128], rate: 8000)
    riff = riff.dup
    riff[20] = "\x03" # set the fmt audio-format to 3 (float), not 1 (PCM)
    err = assert_raises(Wav::Error) { Wav.parse(riff) }
    assert_match(/PCM/i, err.message)
  end

  # --- the DSL path ---

  def with_wav(bytes)
    Tempfile.create(["clip", ".wav"]) do |f|
      f.binmode
      f.write(bytes)
      f.flush
      yield f.path
    end
  end

  def test_sample_from_a_wav_file_plays
    with_wav(wav_bytes(samples: [128, 220, 128, 40] * 8, rate: 8000)) do |path|
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        clip = sample :clip, from: path
        clip.play
        game_loop { wait_vblank }
      end
      i = Reference.new.run(b.program, max_steps: 300)
      assert_includes i.audio, [:sample, :clip], "the WAV-loaded sample plays"
    end
  end

  def test_pcm_and_from_are_mutually_exclusive
    with_wav(wav_bytes(samples: [128], rate: 8000)) do |path|
      err = assert_raises(ArgumentError) do
        Builder.new.instance_eval { screen :bitmap; sample :x, pcm: [0], from: path }
      end
      assert_match(/pcm:.*from:|from:.*pcm:/, err.message)
    end
  end

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
      b.emit_pending_functions
      rom = ROM.assemble(GBA.new.lower(b.program), title: "WAV0", code: "BWAV", maker: "01")
      v = assert_gemba_loads_rom(rom, frames: 6)
      assert v.sound?, "a WAV-loaded sample should play real audio (energy #{v.audio_energy})"
    end
  end
end

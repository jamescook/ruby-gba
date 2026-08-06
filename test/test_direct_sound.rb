# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Direct Sound: `sample :name, pcm: […]` embeds a recorded 8-bit PCM clip and `s.play`
# plays it back through the sampled-audio hardware (a DMA feeds the sound FIFO, a timer
# clocks the rate, a second timer interrupts at the end to stop it). All hidden behind
# sample/play/stop. Pinned on the interpreter (the audio log) and on gemba (real sound).
class TestDirectSound < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  LoweringError = RubyGBA::IR::Backends::GBA::LoweringError

  # A short square-wave clip — a real, audible waveform to play.
  def square_wave(cycles: 250)
    ([100] * 4 + [-100] * 4) * cycles
  end

  # --- the surface behaves (interpreter oracle) ---

  def test_playing_a_sample_registers_on_the_audio_channel
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      boom = sample :boom, pcm: [0, 60, 0, -60] * 8, rate: 8000
      boom.play
      game_loop { wait_vblank }
    end
    i = Reference.new.run(b.program, max_steps: 300)
    assert_includes i.audio, [:sample, :boom], "play put the sample on the audio channel"
  end

  def test_stop_registers_too
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      s = sample :s, pcm: [10, -10], rate: 8000
      s.play
      s.stop
      halt
    end
    log = Reference.new.run(b.program).audio
    assert_equal [[:sample, :s], [:stop_sample]], log
  end

  # --- friendly errors ---

  def test_a_bad_pcm_value_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { screen :bitmap; sample :x, pcm: [0, 200], rate: 8000 }
    end
    assert_match(/-128\.\.127/, err.message)
  end

  def test_playing_an_undefined_sample_is_a_friendly_error
    b = Builder.new
    b.instance_eval { screen :bitmap; play_sample_via_handle = RubyGBA::Sample.new(self, :ghost).play; halt }
    err = assert_raises(Reference::ProgramError) { Reference.new.run(b.program) }
    assert_match(/ghost/, err.message)
  end

  def test_a_clip_longer_than_the_length_counter_still_builds
    # A clip past the 65536-sample length counter used to be a hard error; now it streams
    # straight from ROM in chunks, so it lowers to a ROM without complaint.
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      long = sample :long, pcm: [0, 40, 0, -40] * 20_000, rate: 8000 # 80000 samples, over one chunk
      long.play(loop: true)
      game_loop { wait_vblank }
    end
    code = GBA.new.lower(b.program) # no LoweringError
    assert code.bytesize.positive?, "a long looping clip lowers to a ROM"
  end

  # --- hardware: the sample really sounds on the console ---

  def test_a_sample_plays_real_audio_on_the_console
    b = Builder.new
    wave = square_wave
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      tone = sample :tone, pcm: wave, rate: 8000
      tone.play
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(b.program), title: "PCM0", code: "BPCM", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.sound?, "Direct Sound should be audibly playing the sample (energy #{v.audio_energy})"
  end
end

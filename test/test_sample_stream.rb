# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Streaming a long clip: a PCM clip longer than the 16-bit sample-length counter (65536
# samples) used to be a hard error. Now it plays straight from ROM in equal chunks — the
# DMA just keeps reading the cartridge, and a small chunk counter tracks when the whole
# clip has gone by so it can loop or stop. This is what lets a real, minutes-long track
# loop as background music. The chunking math is the backend's contract, so it's asserted
# directly; the surface is pinned on the interpreter and gemba.
class TestSampleStream < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

  CHUNK = GBA::CHUNK_SAMPLES # 65536 — the most one length-counter pass can span

  def plan(length)
    GBA.new.send(:sample_playback_plan, 8000, length)
  end

  # --- the chunking math (the backend contract) ---

  def test_a_clip_within_the_counter_is_a_single_chunk
    p = plan(1000)
    assert_equal 1, p[:chunks], "a short clip plays in one length-counter pass"
    assert_equal 1000, p[:chunk_len], "the one chunk is the clip's own length"
  end

  def test_a_long_clip_splits_into_chunks_that_each_fit_the_counter
    [CHUNK + 1, 100_000, 500_000, 2_000_000].each do |len|
      p = plan(len)
      assert_operator p[:chunks], :>, 1, "a clip past the counter needs more than one chunk (len #{len})"
      assert_operator p[:chunk_len], :<=, CHUNK, "each chunk fits the 16-bit counter (len #{len})"
      assert_operator p[:chunks] * p[:chunk_len], :>=, len, "the chunks cover the whole clip (len #{len})"
    end
  end

  def test_padding_rounds_a_long_clip_up_to_whole_chunks_from_its_own_start
    len = 100_000
    bytes = ("\x01".b * (len - 4)) + "\x02\x03\x04\x05".b # a distinct head to spot the repeat
    padded = GBA.new.send(:pad_sample_blob, bytes)
    p = plan(len)

    assert_equal p[:chunks] * p[:chunk_len], padded.bytesize, "padded to a whole number of chunks"
    assert_operator padded.bytesize - len, :<, p[:chunks], "only a few samples of padding"
    tail = padded.byteslice(len, padded.bytesize - len)
    assert_equal bytes.byteslice(0, padded.bytesize - len), tail, "the padding repeats the clip's own start"
  end

  # --- the surface plays a long clip on both backends ---

  def test_a_long_looping_clip_still_loops_on_the_interpreter
    b = Builder.new
    clip = [40, -40] * ((CHUNK / 2) + 40) # 65616 samples — just past one chunk
    b.instance_eval do
      screen :bitmap
      music = sample :music, pcm: clip, rate: 200_000 # fast rate so it loops within a few frames
      music.play(loop: true)
      game_loop { wait_vblank }
    end
    i = Ruby.new.run(b.program, max_steps: 20_000)
    plays = i.audio.count { |e| e == [:sample, :music] }
    assert_operator plays, :>, 1, "a clip past the length counter loops just like a short one (#{plays} plays)"
  end

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
    wave = ([90] * 4 + [-90] * 4) * 9_000 # 72000 samples, past one chunk
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      music = sample :music, pcm: wave, rate: 16_000
      music.play(loop: true)
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(b.program), title: "STRM", code: "BSTR", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.sound?, "a long streamed clip should play real audio (energy #{v.audio_energy})"
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Streaming a long clip: a PCM clip longer than the old 65536-sample hardware limit used to
# be a hard error. Now any length just plays — the mixer reads one frame's worth of the clip
# out of the cartridge each frame and advances its play position, so a minutes-long track
# loops as background music with no special handling. Pinned on the interpreter and gemba.
class TestSampleStream < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

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
    i = Ruby.new.run(b.program, max_steps: 20_000)
    plays = i.audio.count { |e| e == [:sample, :music] }
    assert_operator plays, :>, 1, "a clip past the old limit loops just like a short one (#{plays} plays)"
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
    wave = ([90] * 4 + [-90] * 4) * 9_000 # 72000 samples, past the old limit
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

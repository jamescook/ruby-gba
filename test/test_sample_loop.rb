# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Looping a sample: `s.play(loop: true)` replays a clip seamlessly (background music),
# where the default `s.play` plays it once (a one-shot effect). On the console the
# end-of-clip interrupt restarts the sound instead of stopping it; on the interpreter the
# clip re-triggers when it plays out, so the loop shows up in the audio log. Pinned on
# both backends.
class TestSampleLoop < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

  # A one-frame-ish clip, so a few game frames cross its end several times.
  def short_clip
    [50, -50] * 8 # 16 samples ~ a fraction of a frame at 8000 Hz
  end

  # --- the surface behaves (interpreter oracle) ---

  def test_a_one_shot_sample_triggers_only_once
    b = Builder.new
    clip = short_clip
    b.instance_eval do
      screen :bitmap
      s = sample :s, pcm: clip, rate: 8000
      s.play
      game_loop { wait_vblank }
    end
    i = Reference.new.run(b.program, max_steps: 2000)
    plays = i.audio.count { |e| e == [:sample, :s] }
    assert_equal 1, plays, "a one-shot sample plays once and falls silent, no replays"
  end

  def test_a_looping_sample_replays
    b = Builder.new
    clip = short_clip
    b.instance_eval do
      screen :bitmap
      music = sample :music, pcm: clip, rate: 8000
      music.play(loop: true)
      game_loop { wait_vblank }
    end
    i = Reference.new.run(b.program, max_steps: 2000)
    plays = i.audio.count { |e| e == [:sample, :music] }
    assert_operator plays, :>, 1, "a looping sample keeps replaying itself (#{plays} plays)"
  end

  def test_stopping_a_loop_ends_the_replays
    b = Builder.new
    clip = short_clip
    b.instance_eval do
      screen :bitmap
      m = sample :m, pcm: clip, rate: 8000
      m.play(loop: true)
      m.stop
      game_loop { wait_vblank }
    end
    i = Reference.new.run(b.program, max_steps: 2000)
    assert_equal 1, i.audio.count { |e| e == [:sample, :m] }, "a stopped loop does not replay"
    assert_includes i.audio, [:stop_sample]
  end

  # --- hardware: the loop really plays on the console ---
  #
  # A ~2-frame clip looped over 6 frames makes the end-of-clip interrupt fire and restart
  # the sound a few times, so this exercises the loop-restart path on real hardware (not
  # just that it boots) — if the restart wedged the interrupt dispatcher, the frames would
  # not advance and the audio would die.
  def test_a_looping_sample_plays_real_audio_on_the_console
    b = Builder.new
    wave = ([100] * 4 + [-100] * 4) * 32 # 256 samples ~ 2 frames at 8000 Hz
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      music = sample :music, pcm: wave, rate: 8000
      music.play(loop: true)
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(b.program), title: "LOOP", code: "BLOP", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.sound?, "a looping sample should keep the speaker going (energy #{v.audio_energy})"
  end
end

# frozen_string_literal: true

require "test_helper"

# Looping a sample: `s.play(loop: true)` replays a clip seamlessly (background music),
# where the default `s.play` plays it once (a one-shot effect). On the console the
# end-of-clip interrupt restarts the sound instead of stopping it; on the interpreter the
# clip re-triggers when it plays out, so the loop shows up in the audio log. What the
# Advance's speaker plays is heard in the emulator in
# test/lowering/gba/vblank/dsl/test_sample_loop_cartridge.rb.
class TestSampleLoop < Minitest::Test
  # A Game Boy Color has no way to loop a recording, and its build refuses one.
  LOOP_ON_THE_COLOR = "a Game Boy Color plays a recording once, as it was recorded, on its wave voice, " \
                      "and cannot loop it"

  # A one-frame-ish clip, so a few game frames cross its end several times.
  private def short_clip
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
    i = game_player.run(b.program, max_steps: 2000)
    plays = i.audio.count { |e| e == [:sample, :s] }
    assert_equal 1, plays, "a one-shot sample plays once and falls silent, no replays"
  end

  def test_a_looping_sample_replays
    skip_on_console :gbc, LOOP_ON_THE_COLOR
    b = Builder.new
    clip = short_clip
    b.instance_eval do
      screen :bitmap
      music = sample :music, pcm: clip, rate: 8000
      music.play(loop: true)
      game_loop { wait_vblank }
    end
    i = game_player.run(b.program, max_steps: 2000)
    plays = i.audio.count { |e| e == [:sample, :music] }
    assert_operator plays, :>, 1, "a looping sample keeps replaying itself (#{plays} plays)"
  end

  def test_stopping_a_loop_ends_the_replays
    skip_on_console :gbc, LOOP_ON_THE_COLOR
    b = Builder.new
    clip = short_clip
    b.instance_eval do
      screen :bitmap
      m = sample :m, pcm: clip, rate: 8000
      m.play(loop: true)
      m.stop
      game_loop { wait_vblank }
    end
    i = game_player.run(b.program, max_steps: 2000)
    assert_equal 1, i.audio.count { |e| e == [:sample, :m] }, "a stopped loop does not replay"
    assert_includes i.audio, [:stop_sample]
  end
end

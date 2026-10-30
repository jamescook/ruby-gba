# frozen_string_literal: true

require "test_helper"

# Direct Sound: `sample :name, pcm: […]` embeds a recorded 8-bit PCM clip and `s.play`
# plays it back through the sampled-audio hardware (a DMA feeds the sound FIFO, a timer
# clocks the rate, a second timer interrupts at the end to stop it). All hidden behind
# sample/play/stop. Pinned here by the audio log, on every run; the real sound on the
# Advance's cartridge is in test/lowering/gba/vblank/dsl/test_direct_sound_cartridge.rb.
class TestDirectSound < Minitest::Test
  # --- the surface behaves (interpreter oracle) ---

  def test_playing_a_sample_registers_on_the_audio_channel
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      boom = sample :boom, pcm: [0, 60, 0, -60] * 8, rate: 8000
      boom.play
      game_loop { wait_vblank }
    end
    i = game_player.run(b.program, max_steps: 300)
    assert_includes i.audio, [:sample, :boom], "play put the sample on the audio channel"
  end

  # A recording started on one pass and stopped on a later one is heard on every lowering, and
  # stopping it with nothing playing still says so: the play and both stops, on their passes.
  def test_a_recording_started_and_stopped_is_logged_on_its_passes
    b = Builder.new
    b.instance_eval do
      screen :tiled
      hello = sample :hello, pcm: ([80] * 16 + [-80] * 16) * 100
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 3).then { hello.play }
        (count == 9).then { hello.stop }
        (count == 12).then { hello.stop }
      end
    end
    b.finalize_program
    i = game_player.run(b.program, frames: 14)

    assert_equal [[:sample, :hello], [:stop_sample], [:stop_sample]],
                 i.audio.select { |event| %i[sample stop_sample].include?(event.first) }
  end

  # A song with a part on the wave voice, and a recording played over it: every note of the song is
  # still played, by the log, on every lowering, while the recording sounds and after it.
  def test_a_recording_over_a_songs_wave_part_leaves_the_song_playing
    b = Builder.new
    b.instance_eval do
      screen :tiled
      enable_sound
      song :pad do
        tempo 240
        voice(:low, plays: :wave) { |v| 8.times { |n| v.note n.even? ? :A4 : :E4, :quarter } }
      end
      play_song :pad
      hello = sample :hello, pcm: ([80] * 16 + [-80] * 16) * 100
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 3).then { hello.play }
      end
    end
    b.finalize_program
    i = game_player.run(b.program, frames: 130)

    assert_includes i.audio, [:sample, :hello]
    assert_operator i.audio.count { |event| event.first == :voice }, :>=, 8, "the song's notes, through the recording"
  end

  # --- friendly errors ---

  def test_a_bad_pcm_value_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { screen :bitmap; sample :x, pcm: [0, 200], rate: 8000 }
    end
    assert_match(/-128\.\.127/, err.message)
  end
end

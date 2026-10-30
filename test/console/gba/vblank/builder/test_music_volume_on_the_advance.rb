# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/builder/test_music_volume.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# HOW LOUD THE MUSIC PLAYS, moved while it plays.
#
# A part's volume is written into the song. `music_volume` scales every part of whatever song
# is playing, while it plays — a settings screen's music slider, and the level `fade_music_out`
# walks down to silence.
class TestMusicVolumeOnTheAdvance < Minitest::Test
  # A song holding one long note at volume 12 — on the first square voice, or on whichever voice
  # +plays+ names — and a game that runs +body+ on each pass with the pass number. The game names
  # the song on every pass, or with +named_once+ on its first pass only and then whenever +body+
  # says so.
  # With +shaped_elsewhere+ the game also declares a recording with a shape, which it never plays:
  # a game where any note has a shape mixes every voice by its gain rather than its loudness.
  private def held_note_game(plays: nil, named_once: false, shaped_elsewhere: false, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      # A recording that holds, so a long note does not run out before the test is over.
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4, holds_from: 100 if plays == :piano
      sample :pluck, pcm: [40, -40] * 100, rate: 8000, envelope: { release: 0.1 } if shaped_elsewhere
      song :hold do
        tempo 60
        if plays
          voice(:held, plays: plays) do
            volume 12
            note :C4, :whole
          end
        else
          volume 12
          note :C4, :whole
        end
      end
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        named_once ? (pass == 1).then { play_song :hold } : play_song(:hold)
        instance_exec(pass, &body)
      end
    end
    b.finalize_program
    b.program
  end

  # How loud each voice was set, on the frames it was set, from the interpreter:
  # { frame => [[channel, volume 0..15], ...] }. With +stops+, a frame the music stopped on
  # says :stop_music among them.
  private def loudness_by_frame(program, frames, stops: false)
    i = game_player
    heard = {}
    logged = 0
    i.each_vblank do |frame|
      fresh = i.audio.drop(logged).filter_map do |entry|
        next entry.drop(1) if entry[0] == :loudness

        :stop_music if stops && entry[0] == :stop_music
      end
      logged = i.audio.size
      heard[frame] = fresh unless fresh.empty?
    end
    i.run(program, frames: frames)
    heard
  end

  # --- a part that plays a recording ---

  # A recorded part sounds on a voice of the mixer, whose loudness runs 0..512 rather than 0..15 —
  # volume 12 is 410 of those — and the mixer takes a new one while a note plays, like the wave
  # voice. The log names the part by its place among the song's recorded parts.
  def test_half_the_music_volume_halves_a_recorded_note_already_sounding
    program = held_note_game(plays: :piano) { |pass| (pass == 5).then { music_volume 50 } }

    assert_equal({ 2 => [[[:mixer, 0], 410]], 6 => [[[:mixer, 0], 205]] }, loudness_by_frame(program, 10))
  end

  # A note with no shape follows the music volume in a game where some other note has one, too.
  # Such a game mixes every voice by a gain the shapes work out a frame at a time, and a note
  # with no shape has none to work it out.
  def test_no_music_volume_silences_a_recorded_note_without_a_shape_in_a_game_that_shapes
    program = held_note_game(plays: :piano, shaped_elsewhere: true) { |pass| (pass == 20).then { music_volume 0 } }
    i = game_player
    i.run(program, frames: 40)
    peaks = i.mixed_sound.map { |slice| slice.map(&:abs).max }

    assert_operator peaks[5..15].min, :>, 0, "the note sounds at its own volume (#{peaks.inspect})"
    assert_equal [0], peaks[25..].uniq, "and is silent once the music volume is 0 (#{peaks.inspect})"
  end
end

# frozen_string_literal: true

require "test_helper"

# A PART PLAYED HIGHER OR LOWER than it is written — moved by whole semitones (`transpose`), or
# by a few of the voice's own pitch steps, a little sharp or flat (`pitch_offset`), which is what
# another game's music engine arrives saying. Both are worked into each note's pitch when the game
# is built, so every backend plays the same pitches and no player does anything new.
class TestSongPitchShifts < Minitest::Test
  Sound = VBlank::Audio::Sound

  private def song_game(&parts)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150
        instance_eval(&parts)
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The pitch of every note set on +voice+, in the order played, rests left out.
  private def pitches_on(program, voice, frames: 30)
    game_player.run(program, frames: frames).audio.filter_map do |kind, on, _who, pitch|
      pitch if kind == :voice && on == voice && pitch.positive?
    end
  end

  def test_a_part_transposed_up_an_octave_plays_twice_as_high
    played = pitches_on(song_game do
      voice(:lead) { |v| v.transpose 12; v.note :A4, :quarter; v.note 300, :quarter }
    end, 1, frames: 50)

    assert_in_delta 880.0, played[0], 0.01
    assert_in_delta 600.0, played[1], 0.01
  end

  def test_a_part_transposed_down_a_fifth
    played = pitches_on(song_game { voice(:bass, plays: :wave) { |v| v.transpose(-7); v.note :E4, :whole } }, 3)

    assert_in_delta 330 * (2**(-7 / 12.0)), played.first, 0.01
  end

  # A PITCH OFFSET is the voice's own steps: the note plays at its key's pitch number and that many
  # more, which on a square voice is a wave a tick shorter for each.
  def test_a_pitch_offset_moves_the_voices_own_pitch_number
    played = pitches_on(song_game { voice(:lead) { |v| v.pitch_offset 3; v.note :A4, :whole } }, 1)
    ticks = Sound.square_wave_ticks(440) - 3

    assert_equal ticks, Sound.square_wave_ticks(played.first), "three steps up"
    assert_in_delta Sound::SQUARE_CLOCK_HZ.to_f / ticks, played.first, 0.001
  end

  # Transposed first, then offset, on the wave voice's own clock.
  def test_a_transpose_and_an_offset_together_on_the_wave_voice
    played = pitches_on(song_game do
      voice(:pad, plays: :wave) { |v| v.transpose 12; v.pitch_offset(-2); v.note :C3, :whole }
    end, 3)

    assert_equal Sound.wave_voice_ticks(131 * 2) + 2, Sound.wave_voice_ticks(played.first)
  end

  # A SCORE SAYS IT THE SAME WAY, on a part.
  def test_a_score_part_transposes_and_offsets
    score = VBlank::Audio::Score
    lead = score::Part.new(transpose: 12, pitch_offset: 1, notes: [score::Note.new(at: 0, key: 69, length: 24)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      songs(:music, [score.new(parts: [lead], tempo: 150)]).play 0
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal Sound.square_wave_ticks(880) - 1, Sound.square_wave_ticks(pitches_on(b.program, 1).first)
  end

  # A NOTE AT THE VOICE'S OWN PITCH NUMBER, as another Game Boy game's music engine says it: 1601 is
  # D#3 in one such game's table, a step away from the 1602 the key's own pitch comes to.
  private def pitch_number_game(plays)
    score = VBlank::Audio::Score
    part = score::Part.new(plays: plays, pitch_offset: 2, notes: [score::Note.new(at: 0, pitch_number: 1601, length: 24)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      songs(:music, [score.new(parts: [part], tempo: 150)]).play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_a_note_plays_at_the_square_voices_own_pitch_number
    played = pitches_on(pitch_number_game(nil), 1).first

    assert_equal 2048 - 1603, Sound.square_wave_ticks(played), "1601, and the part's two steps up"
  end

  def test_a_note_plays_at_the_wave_voices_own_pitch_number
    played = pitches_on(pitch_number_game(:wave), 3).first

    assert_equal 2048 - 1603, Sound.wave_voice_ticks(played)
  end

  def test_a_drum_has_no_pitch_number
    score = VBlank::Audio::Score
    part = score::Part.new(plays: :noise, notes: [score::Note.new(at: 0, pitch_number: 1601)])
    error = assert_raises(ArgumentError) { score.new(parts: [part]).to_song }

    assert_match(/pitch_number/, error.message)
    assert_match(/square part or the wave part/, error.message)
  end

  def test_a_pitch_number_is_0_to_2047
    score = VBlank::Audio::Score
    part = score::Part.new(notes: [score::Note.new(at: 0, pitch_number: 2048)])
    error = assert_raises(ArgumentError) { score.new(parts: [part]).to_song }

    assert_match(/0 to 2047/, error.message)
  end

  # --- what a shift cannot be ---

  def test_the_drums_have_no_pitch_steps_to_offset
    error = assert_raises(ArgumentError) { song_game { voice(:drums, plays: :noise) { |v| v.pitch_offset 2 } } }

    assert_match(/:drums/, error.message)
    assert_match(/square part or the wave part/, error.message)
  end

  def test_a_part_that_plays_a_recording_has_no_pitch_steps_to_offset
    error = assert_raises(ArgumentError) { song_game { voice(:keys, plays: :piano) { |v| v.pitch_offset 1 } } }

    assert_match(/:keys/, error.message)
    assert_match(/recording/, error.message)
  end

  def test_an_offset_past_the_top_of_the_voice_names_the_note
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.pitch_offset 2000; v.note :A4, :quarter } } }

    assert_match(/higher than the voice can play/, error.message)
  end

  def test_an_offset_past_the_bottom_of_the_voice_names_the_note
    error = assert_raises(ArgumentError) do
      song_game { voice(:pad, plays: :wave) { |v| v.rest :quarter; v.pitch_offset(-2000); v.note :C3, :quarter } }
    end

    assert_match(/0.4 seconds in/, error.message)
    assert_match(/lower than the voice can play/, error.message)
  end

  # A SCORE'S PART is checked the same way, and the message names it as a Score names its parts.
  def test_a_score_part_offset_on_the_drums_is_refused
    score = VBlank::Audio::Score
    drums = score::Part.new(plays: :noise, pitch_offset: 1, notes: [score::Note.new(at: 0, key: 40, length: 24)])
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval { songs :music, [score.new(parts: [drums], tempo: 150)] }
    end

    assert_match(/noise voice/, error.message)
  end

  def test_a_transpose_that_is_not_a_whole_number_of_semitones_is_refused
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.transpose 1.5 } } }

    assert_match(/whole number/, error.message)
  end
end

# frozen_string_literal: true

require "test_helper"
require "speakers"

# A SONG'S PARTS THAT PLAY FROM ONE SPEAKER — the left, the right, or both, which is what every
# part does when it says nothing. A part says its side (`v.pan :left`), and a note can say its own
# (`pan: :right`), so a part can move from side to side as the song goes.
#
# The log names the side each note plays from at the end of its [:voice] entry, after its fade,
# slide and wobble, and says nothing for both sides.
class TestSongPan < Minitest::Test
  include Speakers

  private def song_game(&parts)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150 # a quarter is 24 frames
        instance_eval(&parts)
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Each note's [:voice] entry, as [voice, pitch, side], the side nil for both.
  private def sides_logged(program, frames:)
    game_player.run(program, frames: frames).audio.filter_map do |kind, voice, _who, pitch, _volume, *said|
      [voice, pitch, said[3]] if kind == :voice && pitch.positive?
    end
  end

  def test_a_left_part_and_a_right_part_each_play_from_their_side
    played = sides_logged(song_game do
      voice(:lead) { |v| v.pan :left; v.note :C5, :whole }
      voice(:harmony) { |v| v.pan :right; v.note :E4, :whole }
      voice(:bass, plays: :wave) { |v| v.note :C3, :whole }
    end, frames: 4)

    assert_equal [[1, :left], [2, :right], [3, nil]], played.map { |voice, _, side| [voice, side] }.sort_by(&:first)
  end

  # A note says its own side, and :center plays one from both in a part that pans.
  def test_a_note_says_its_own_side
    played = sides_logged(song_game do
      voice :lead do |v|
        v.pan :left
        v.note :C5, :quarter
        v.note :D5, :quarter, pan: :right
        v.note :E5, :quarter, pan: :center
        v.note :F5, :quarter
      end
    end, frames: 100)

    assert_equal %i[left right] + [nil] + %i[left], played.first(4).map(&:last)
  end

  def test_the_drums_can_pan
    played = sides_logged(song_game { voice(:drums, plays: :noise) { |v| v.pan :right; v.note :C2, :quarter } }, frames: 4)

    assert_equal [[4, :right]], played.map { |voice, _, side| [voice, side] }
  end

  # A SCORE SAYS IT THE SAME WAY: a part's `pan:` and a note's own.
  def test_a_score_says_which_side_its_notes_play_from
    score = VBlank::Audio::Score
    lead = score::Part.new(pan: :left, notes: [score::Note.new(at: 0, key: 72, length: 24),
                                               score::Note.new(at: 24, key: 74, length: 24, pan: :right)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      songs(:music, [score.new(parts: [lead], tempo: 150)]).play 0
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal %i[left right], sides_logged(b.program, frames: 30).map(&:last)
  end

  # THE CARTRIDGE, heard in the emulator: each voice from its own speaker alone, the drums and the
  # wave voice included, and a part that says nothing from both.
  def test_the_cartridge_plays_each_part_from_its_own_speaker
    require_emulator!
    game = song_game do
      voice(:lead) { |v| v.pan :left; v.note :C5, :whole }
      voice(:harmony) { |v| v.pan :right; v.note :E4, :whole }
      voice(:bass, plays: :wave) { |v| v.pan :left; v.note :C3, :whole }
      voice(:drums, plays: :noise) { |v| v.note :C4, :whole, decay: :none }
    end
    { square1: :left, square2: :right, wave: :left, noise: :both }.each do |voice, side|
      assert_heard_from side, loudest_on_each_side(game, voice, frames: 40, from: 10), voice
    end
  end

  # THE GAME'S OWN SOUND — a beep, a hit on the noise voice, a tone on the wave voice — plays from
  # both speakers, on the voice a song's note left at the right.
  def test_the_games_own_sound_after_a_panned_note_plays_from_both_speakers
    require_emulator!
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150
        voice(:lead) { |v| v.rest :whole }
        voice(:harmony) { |v| v.pan :right; v.note :E4, :whole }
        voice(:pad, plays: :wave) { |v| v.pan :right; v.note :C3, :whole }
        voice(:drums, plays: :noise) { |v| v.pan :right; v.note :C4, :whole, decay: :none }
      end
      play_song :tune
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 40).then do
          beep 880, decay: :none
          noise :kick, decay: :none
          wave :sawtooth, :A3, volume: :half
        end
        wait_vblank
      end
    end
    b.finalize_program

    %i[square2 wave noise].each do |voice|
      assert_heard_from :both, loudest_on_each_side(b.program, voice, frames: 60, from: 45), voice
    end
  end

  # --- what a side cannot be said of ---

  def test_a_recorded_part_cannot_pan
    error = assert_raises(ArgumentError) { song_game { voice(:keys, plays: :piano) { |v| v.pan :left } } }

    assert_match(/:keys/, error.message)
    assert_match(/recording/, error.message)
  end

  def test_a_side_that_is_not_one_says_what_it_can_be
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.note :C5, :quarter, pan: :up } } }

    assert_match(/:left, :right/, error.message)
  end
end

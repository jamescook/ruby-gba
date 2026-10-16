# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A SOUND EFFECT THAT PLAYS A RECORDING COSTS THE ROUTINE THAT ANSWERS THE DISPLAY, which
# every frame runs and which is kept in the quick memory first.
#
# Such an effect makes every note in the game rank against every other for a voice, and a
# song's notes rank by the song's rank, which is a variable. That rank used to be put on a
# song's mark at every place a recorded part starts a note, rests or goes quiet — written out
# again for every recorded part of every song — and a voice nobody could have was tested for
# at every place a note starts, so one shout cost a game more the more recorded parts its songs
# had. Now the voice routines put the rank on, once, and a note with no voice is written to a
# slot nothing mixes, so the cost is the same however many parts there are.
#
# A GAME WITH A RECORDED EFFECT NEARLY ALWAYS HAS TONE ONES TOO, and then the routine keeps the
# code for both kinds. Starting a recorded note — the voice, the recording, how fast, how loud,
# its shape — used to be written out whole at each place one starts: once for every recorded part
# of every song, and once more for the effects. It is one routine now, called from each.
class TestRecordedEffectCost < Minitest::Test
  Score = RubyGBA::Audio::Score

  # The size of the routine that answers the display, for a game whose song has +parts+
  # recorded parts and whose sound effects play +effects+ (each a recording's name, or nil for
  # the square wave).
  private def answering_routine(parts, effects)
    notes = %i[C4 E4].each_with_index.map { |key, n| Score::Note.new(at: n * 10, key: key) }
    game = RubyGBA.game "COST" do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 400, rate: 8000, note: :C4
      music = songs :music, [Score.new(tempo: 150, parts: Array.new(parts) { Score::Part.new(plays: :piano, notes: notes) })]
      list = effects.map { |plays| Score.new(tempo: 150, parts: [Score::Part.new(plays: plays, notes: notes)]) }
      sfx = sound_effects :sfx, list
      game_loop do
        music.play 0
        pressed(:a).then { sfx.play 0 }
      end
    end
    game.build_rom(out: StringIO.new, err: StringIO.new, profile: false).built.placement.sizes.fetch(:__interrupt)
  end

  # What a game whose sound effects play the square wave pays for one more that plays a recording.
  private def recorded_effect_cost(parts) = answering_routine(parts, [nil, :piano]) - answering_routine(parts, [nil, nil])

  def test_a_recorded_effect_costs_the_same_however_many_recorded_parts_the_songs_have
    assert_equal recorded_effect_cost(4), recorded_effect_cost(16)
  end

  # ...and what it costs is small beside the routine itself: the effect's own walk to its note and
  # the calls that start it and let it go, the ranking in the voice routines, and the count of
  # sounds that found no voice. Writing the note out at the effect again would put it past this.
  def test_a_recorded_effect_beside_square_wave_ones_costs_under_352_bytes
    cost = recorded_effect_cost(16)

    assert_operator cost, :<, 352, "a recorded effect costs the routine #{cost} bytes"
  end

  # A GAME WHOSE ONE EFFECT PLAYS A RECORDING keeps none of the square-wave effects' code, so there
  # the recording costs less again: what it adds, less what it no longer needs.
  def test_a_lone_recorded_effect_costs_under_a_quarter_of_a_kilobyte
    cost = answering_routine(16, [:piano]) - answering_routine(16, [nil])

    assert_operator cost, :<, 256, "a lone recorded effect costs the routine #{cost} bytes"
  end

  # A SONG'S RECORDED PART costs the routine its place in the walk and a call, not a copy of the
  # whole note: a game whose music is a dozen recorded parts would otherwise spend kilobytes of the
  # quick memory writing the same note out a dozen times. The whole note written out again would
  # put a part past this.
  def test_a_recorded_song_part_costs_the_routine_a_call_not_a_whole_note
    each_part = (answering_routine(16, [nil]) - answering_routine(4, [nil])) / 12

    assert_operator each_part, :<, 128, "each recorded song part costs the routine #{each_part} bytes"
  end
end

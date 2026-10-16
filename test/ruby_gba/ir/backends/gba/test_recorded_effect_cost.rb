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
class TestRecordedEffectCost < Minitest::Test
  Score = RubyGBA::Audio::Score

  # The size of the routine that answers the display, for a game whose song has +parts+
  # recorded parts and whose one sound effect plays +effect+ (a recording's name, or nil for
  # the square wave).
  private def answering_routine(parts, effect)
    notes = %i[C4 E4].each_with_index.map { |key, n| Score::Note.new(at: n * 10, key: key) }
    game = RubyGBA.game "COST" do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 400, rate: 8000, note: :C4
      music = songs :music, [Score.new(tempo: 150, parts: Array.new(parts) { Score::Part.new(plays: :piano, notes: notes) })]
      sfx = sound_effects :sfx, [Score.new(tempo: 150, parts: [Score::Part.new(plays: effect, notes: notes)])]
      game_loop do
        music.play 0
        pressed(:a).then { sfx.play 0 }
      end
    end
    game.build_rom(out: StringIO.new, err: StringIO.new, profile: false).built.placement.sizes.fetch(:__interrupt)
  end

  private def recorded_effect_cost(parts) = answering_routine(parts, :piano) - answering_routine(parts, nil)

  def test_a_recorded_effect_costs_the_same_however_many_recorded_parts_the_songs_have
    assert_equal recorded_effect_cost(4), recorded_effect_cost(16)
  end

  # ...and what it costs is small beside the routine itself: the effect's own note, the
  # ranking in the voice routines, and the count of sounds that found no voice. A quarter of
  # a kilobyte is twice that, so a cost that grows back to what it was is caught here.
  def test_a_recorded_effect_costs_under_a_quarter_of_a_kilobyte
    cost = recorded_effect_cost(16)

    assert_operator cost, :<, 256, "a recorded effect costs the routine #{cost} bytes"
  end
end

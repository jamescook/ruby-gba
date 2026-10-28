# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/chip_band").to_s

# The chip band example (examples/chip_band.rb): a list of tunes on the console's own voices, the
# one the cursor is on playing. HELD NOTES holds every note; FADING NOTES is the same notes,
# faded and swelled by the voices. Played on every lowering, on the console each run plays a
# game as.
class TestChipBandExample < Minitest::Test
  NoteFade = VBlank::Audio::NoteFade

  # What the voices were set to over +frames+ passes, as [song, voice, fade], with DOWN tapped
  # on the pass +down_at+ when it is given.
  private def voices_set(frames, down_at: nil)
    player = game_player
    pass = 0
    player.input_each_frame { (pass += 1) == down_at ? [:down] : [] } if down_at
    player.run(ChipBand.program(console: game_console), frames: frames).audio
          .select { |entry| entry.first == :voice }
          .map { |_, voice, song, pitch, _volume, fade| [song, voice, fade] unless pitch.zero? }.compact
  end

  def test_the_first_tune_holds_every_note
    played = voices_set(60)

    refute_empty played
    assert_equal [:held], played.map(&:first).uniq
    assert_equal [nil], played.reject { |_, voice, _| voice == 4 }.map(&:last).uniq,
                 "a square note that says nothing holds"
  end

  def test_the_second_tune_fades_its_lead_and_swells_its_chords
    played = voices_set(90, down_at: 5).select { |song, _, _| song == :fading }
    lead = played.select { |_, voice, _| voice == 1 }.map(&:last).uniq
    chords = played.select { |_, voice, _| voice == 2 }.map(&:last).uniq
    drums = played.select { |_, voice, _| voice == 4 }.map(&:last).uniq

    assert_equal [NoteFade.down(3)], lead, "the lead is plucked"
    assert_equal [NoteFade.up(7)], chords, "the chords breathe in"
    assert_includes drums, NoteFade.up(4), "the last hit of a bar swells in"
  end
end

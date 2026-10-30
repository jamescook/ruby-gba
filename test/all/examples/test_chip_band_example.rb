# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/chip_band").to_s

# The chip band example (examples/chip_band.rb): a list of tunes on the console's own voices, the
# one the cursor is on playing. HELD NOTES holds every note; FADING NOTES is the same notes,
# faded and swelled by the voices; SLIDING NOTES slides the lead's pitch, WOBBLING NOTES wobbles
# it, LEFT AND RIGHT spreads the parts across the two speakers, SHIMMERING NOTES steps the lead's
# shapes, and DETUNED NOTES plays the lead sharp beside itself and an octave down. Played on every
# lowering, on the console each run plays a game as.
class TestChipBandExample < Minitest::Test
  NoteFade = VBlank::Audio::NoteFade

  # The sound log of a run that moves the cursor down +downs+ times and then plays on for a while.
  # Each press is held for a few frames and let go for a while, the way a person presses: the Color
  # takes its first frames setting the game up, and a press over before the game looks is missed.
  private def log_after(downs)
    skip_on_snes "the chip band is made for the Game Boy Advance and the Game Boy Color, not the Super Nintendo"
    player = game_player
    frame = 0
    player.input_each_frame do
      frame += 1
      (frame % 20).between?(1, 3) && frame / 20 < downs ? [:down] : []
    end
    player.run(ChipBand.program(console: game_console), frames: (20 * downs) + 70).audio
  end

  # What the voices of +song+ were set to, as [voice, fade], leaving out rests.
  private def voices_set(log, song)
    log.select { |entry| entry.first == :voice && entry[2] == song && entry[3].positive? }
       .map { |_, voice, _song, _pitch, _volume, fade| [voice, fade] }
  end

  def test_the_first_tune_holds_every_note
    played = voices_set(log_after(0), :held)

    refute_empty played
    assert_equal [nil], played.reject { |voice, _| voice == 4 }.map(&:last).uniq,
                 "a square note that says nothing holds"
  end

  def test_the_second_tune_fades_its_lead_and_swells_its_chords
    played = voices_set(log_after(1), :fading)
    of = ->(voice) { played.select { |on, _| on == voice }.map(&:last).uniq }

    assert_equal [NoteFade.fading(3)], of.call(1), "the lead is plucked"
    assert_equal [NoteFade.swelling(7)], of.call(2), "the chords breathe in"
    assert_includes of.call(4), NoteFade.swelling(4), "the last hit of a bar swells in"
  end

  def test_the_third_tune_zaps_and_swoops_its_lead
    slides = log_after(2).select { |entry| entry.first == :voice && entry[1] == 1 && entry[2] == :sliding && entry[3].positive? }
                         .map(&:last).uniq
    slide = VBlank::Audio::PitchSlide

    assert_equal [slide.upward(every: 1, shift: 5), slide.downward(every: 7, shift: 5)].sort_by(&:direction),
                 slides.sort_by(&:direction), "eighths zap up, longer notes swoop down"
  end

  def test_the_fourth_tune_wobbles_its_lead_and_its_chords
    log = log_after(3)
    vibratos = log.select { |entry| entry.first == :voice && entry[2] == :wobbling && entry[3].positive? }
                  .to_h { |entry| [entry[1], entry.last] }
    vibrato = VBlank::Audio::Vibrato

    assert_equal vibrato.new(depth: 4, speed: 4, after: 14), vibratos[1], "the lead waits an eighth"
    assert_equal vibrato.new(depth: 2, speed: 8, after: 0), vibratos[2], "the chords wobble slightly and slowly"
    assert(log.any? { |entry| entry.first == :wobble }, "and the voices move")
  end

  # The [:voice] entry names a note's speaker last, after its fade, slide and wobble.
  def test_the_fifth_tune_spreads_its_parts_across_the_speakers
    sides = log_after(4).select { |entry| entry.first == :voice && entry[2] == :spread && entry[3].positive? }
                        .group_by { |entry| entry[1] }.transform_values { |entries| entries.map { |entry| entry[8] }.uniq }

    assert_equal [:left], sides[1], "the lead on the left"
    assert_equal [:right], sides[2], "the chords on the right"
    assert_equal [nil, :left, :right].sort_by(&:to_s), sides[4].sort_by(&:to_s), "the kicks on both, the hats side to side"
  end

  def test_the_sixth_tune_steps_its_leads_shapes_and_gives_each_chord_its_own
    log = log_after(5)
    shapes = log.select { |entry| entry.first == :voice && entry[2] == :shimmering && entry[3].positive? }
                .group_by { |entry| entry[1] }.transform_values { |entries| entries.map { |entry| entry[9] }.uniq }
    duty = VBlank::Audio::Duty

    assert_equal [duty.said(%i[eighth quarter half quarter], where: "the lead")], shapes[1], "the lead's four shapes"
    assert_equal duty.said(:eighth, where: "a chord"), shapes[2].first, "the first chord's own"
    assert(log.any? { |entry| entry.first == :duty && entry[1] == 1 }, "and the lead steps them")
  end

  def test_the_seventh_tune_plays_its_lead_sharp_and_an_octave_down
    first = log_after(6).select { |entry| entry.first == :voice && entry[2] == :detuned && entry[3].positive? }
                        .group_by { |entry| entry[1] }.transform_values { |entries| entries.first[3] }
    sound = VBlank::Audio::Sound

    assert_equal sound.square_wave_ticks(first[1]) - 2, sound.square_wave_ticks(first[2]), "the chorus two steps sharp"
    assert_in_delta first[1] / 2.0, first[3], 0.01, "the bass an octave down"
  end
end

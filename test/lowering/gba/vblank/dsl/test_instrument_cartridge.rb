# frozen_string_literal: true

require "test_helper"

# AN INSTRUMENT'S CHORD ON THE ADVANCE'S CARTRIDGE, read in the emulator: three distinct pitched
# voices. The instrument on every run is in test/all/vblank/dsl/test_instrument.rb, and the notes
# only the Advance plays in test/console/gba/vblank/dsl/test_instrument_on_the_advance.rb.
class TestInstrumentCartridge < Minitest::Test
  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  # --- hardware: a chord is three distinct pitched voices ---

  def test_a_chord_plays_distinct_pitches_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      piano = instrument :piano, pcm: [50, -50] * 3000, rate: 8000, note: :C4 # long enough to hold the chord
      piano.play(:C4, :E4, :G4)
      game_loop { wait_vblank }
    end
    b.finalize_program
    v = assert_emulator_loads_rom(assemble_rom(b.program, name: "CHRD"), frames: 6)

    chord = %i[C4 E4 G4]
    steps = v.voices.map(&:step)
    # The mix runs at a rate the sound hardware can sustain rather than at the rate the
    # recording was made at, and a step carries both that and the note's own pitch.
    resample = 8000.0 / v.sample_clock.rate
    expected = chord.map { |n| (NOTES[n].to_f / NOTES[:C4] * resample * GBA::Mixer::STEP_ONE).round }

    assert v.sound?, "the chord should be audible (energy #{v.audio_energy})"
    assert_equal 3, steps.uniq.size, "the chord is three distinct pitches, got steps #{steps.inspect}"
    steps.zip(expected).each do |got, exp|
      assert_in_delta exp, got, 2, "each voice steps at its note's ratio (#{got} ~ #{exp})"
    end
  end
end

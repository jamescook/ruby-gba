# frozen_string_literal: true

require "test_helper"

# The sine these tests and the Advance cartridge's own tests of the envelope play
# (test/lowering/gba/vblank/audio/test_note_envelope_cartridge.rb).
module NoteEnvelopeSounds
  # A cycle of a sine, so a recording made of whole cycles has no step in it.
  CYCLE = 64
  RATE = 8000
  SINE = (0...CYCLE).map { |i| (Math.sin(i * 2 * Math::PI / CYCLE) * 100).round }.freeze
end

# HOW A NOTE STARTS AND HOW IT ENDS — the shape of its loudness over time, and the two things
# that shape buys: a note that ends without a click, and a note that can outlast the recording
# it is made of. Both of those are heard on the Advance's cartridge, in
# test/lowering/gba/vblank/audio/test_note_envelope_cartridge.rb; here are the numbers an
# envelope keeps and what an author is told when they write one wrong.
class TestNoteEnvelope < Minitest::Test
  include NoteEnvelopeSounds

  # The four numbers, and the two ways an author can say them.
  def test_a_time_becomes_the_number_that_takes_about_that_long
    env = VBlank::Audio::Envelope.of({ release: 0.4 }, "a part")

    assert_equal 24, VBlank::Audio::Envelope.frames_to_fall(env.release, VBlank::Audio::Envelope::FULL, 0)
    assert_equal VBlank::Audio::Envelope::MOST, env.attack, "a time of nothing is full at once"
    assert_equal VBlank::Audio::Envelope::MOST, env.sustain, "what is not said holds where it was"
  end

  def test_the_numbers_the_consoles_own_engine_keeps_are_taken_as_they_are
    env = VBlank::Audio::Envelope.new(attack: 255, decay: 245, sustain: 180, release: 216)

    assert_equal 216, env.release
    assert_equal 0xD8_B4_F5_FF, env.packed
  end

  def test_an_envelope_that_says_nothing_is_the_note_as_it_always_was
    assert_predicate VBlank::Audio::Envelope.of({}, "a part"), :plain?
    refute_predicate VBlank::Audio::Envelope.of({ release: 0.2 }, "a part"), :plain?
  end

  # The rule that moves the level, which both backends follow.
  def test_the_level_climbs_holds_and_falls_away
    env = VBlank::Audio::Envelope.new(attack: 64, decay: 128, sustain: 100, release: 128)
    level, phase = env.step(0, VBlank::Audio::Envelope::CLIMBING)

    assert_equal [64, VBlank::Audio::Envelope::CLIMBING], [level, phase]
    level, phase = env.step(200, VBlank::Audio::Envelope::CLIMBING)

    assert_equal [VBlank::Audio::Envelope::FULL, VBlank::Audio::Envelope::HOLDING], [level, phase]
    assert_equal [127, VBlank::Audio::Envelope::HOLDING], env.step(255, VBlank::Audio::Envelope::HOLDING)
    assert_equal [100, VBlank::Audio::Envelope::HOLDING], env.step(100, VBlank::Audio::Envelope::HOLDING),
                 "it holds at the sustain level rather than falling through it"
    assert_equal [50, VBlank::Audio::Envelope::FALLING], env.step(100, VBlank::Audio::Envelope::FALLING)
  end

  # --- what an author is told when they write it wrong ---

  def test_a_time_that_is_not_a_time_names_itself
    error = assert_raises(ArgumentError) { VBlank::Audio::Envelope.of({ release: :slow }, "the part :lead") }

    assert_match(/the part :lead/, error.message)
    assert_match(/release/, error.message)
  end

  def test_a_key_the_envelope_does_not_have_names_itself
    error = assert_raises(ArgumentError) { VBlank::Audio::Envelope.of({ fade: 0.2 }, "the part :lead") }

    assert_match(/fade/, error.message)
    assert_match(/attack/, error.message)
  end

  def test_a_sustain_outside_its_range_names_itself
    error = assert_raises(ArgumentError) { VBlank::Audio::Envelope.of({ sustain: 4 }, "the part :lead") }

    assert_match(/sustain/, error.message)
  end

  def test_one_of_the_four_numbers_outside_its_range_names_itself
    error = assert_raises(ArgumentError) { VBlank::Audio::Envelope.new(attack: 300) }

    assert_match(/attack/, error.message)
    assert_match(/0 to 255/, error.message)
  end

  def test_a_hold_point_outside_the_recording_names_itself
    error = assert_raises(ArgumentError) do
      VBlank.build("ENVELOPE", console: :gba, code: "BENV", maker: "01", validate: false) do
        screen :bitmap
        enable_sound
        instrument :tone, pcm: SINE, rate: RATE, note: :C4, holds_from: 5.0
      end
    end

    assert_match(/holds from/, error.message)
    assert_match(/:tone/, error.message)
  end
end

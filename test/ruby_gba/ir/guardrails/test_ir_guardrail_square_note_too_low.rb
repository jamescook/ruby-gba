# frozen_string_literal: true

require "test_helper"

require "stringio"

# The square-wave voice has a lowest pitch, 64 Hz, and a lower note is played AT it — a different
# note, with nothing to say so. A song block's note names never go that low, but a pitch in Hz can,
# and a Score's MIDI keys reach it easily. The build warns, naming the note and the lowest one that
# sounds right, and still builds: the song plays, one note of it wrong.
class TestSquareNoteTooLowGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::SquareNoteTooLow
  Registers = RubyGBA::Audio::Sound::Registers
  Part = RubyGBA::Audio::Score::Part
  Note = RubyGBA::Audio::Score::Note

  private def detect(hz, instrument: nil)
    voice = RubyGBA::Audio::Music::Part.new(events: [[0, hz], [4, 0]], instrument: instrument)
    Check.new.detect(program(song(:low, total_frames: 8, voices: [voice])))
  end

  # WHY IT IS WORTH SAYING: below the bottom, different notes come out as one pitch.
  def test_two_different_notes_under_the_bottom_sound_the_same
    assert_equal Registers.frequency_value(64), Registers.frequency_value(49)
    assert_equal Registers.frequency_value(64), Registers.frequency_value(33)
    refute_equal Registers.frequency_value(64), Registers.frequency_value(65), "C2 is above it, and in tune"
  end

  def test_a_note_under_the_bottom_warns_with_the_note_and_the_lowest_that_sounds_right
    findings = detect(49)

    assert_equal 1, findings.length
    assert findings.first.warning?, "the song still plays"
    assert_match(/49 Hz \(MIDI key 31\)/, findings.first.message)
    assert_match(/:C2 \(MIDI key 36\)/, findings.first.message)
  end

  def test_c2_and_above_is_quiet
    assert_empty detect(RubyGBA::Audio::Music::NOTE_FREQUENCIES[:C2])
  end

  def test_a_part_that_plays_an_instrument_has_no_such_bottom
    assert_empty detect(49, instrument: :cello)
  end

  # --- through the build ---

  private def warnings(&program)
    err = StringIO.new
    RubyGBA.build("LOWNOTE", code: "ZLOW", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      enable_sound
      instance_exec(&program)
      game_loop { wait_vblank }
    end
    err.string
  end

  def test_a_score_names_the_part_by_its_index
    bass = Part.new(notes: [Note.new(at: 0, key: 60), Note.new(at: 24, key: 24), Note.new(at: 48, key: 28)])
    said = warnings { songs(:music, { forest: RubyGBA::Audio::Score.new(parts: [Part.new(notes: []), bass]) }).play :forest }

    assert_match(/Part 1 of the song :forest of :music plays a note at 33 Hz \(MIDI key 24\)/, said)
    assert_match(/2 notes that are too low/, said)
  end

  # MUSIC LIFTED OFF A CARTRIDGE ALREADY PLAYED THESE NOTES AT THE BOTTOM. A cartridge's own sound
  # engine clamps a key below C2 to C2 before the console ever sees it, so a decoded sound effect
  # with a note down there is playing what the original played, and every way out the warning
  # offers would change the sound. A Score says so, and is quiet; a hand-written part beside it
  # in the same cartridge still warns.
  def test_a_score_that_says_its_low_notes_are_clamped_is_quiet_and_others_still_warn
    low = Part.new(notes: [Note.new(at: 0, key: 27)])
    decoded = RubyGBA::Audio::Score.new(parts: [low], low_notes_intended: true)
    written = RubyGBA::Audio::Score.new(parts: [low])
    said = warnings do
      sfx = sound_effects(:sfx, { death: decoded, thud: written })
      sfx.play :death
      sfx.play :thud
    end

    refute_match(/:death/, said, "the decoded effect plays what the original played")
    assert_match(/sound effect :thud of :sfx plays a note at 39 Hz/, said)
    assert_match(/write `low_notes_intended: true` on its Score/, said, "and the warning says how")
  end

  # ...and the same for a song handed over as a Score.
  def test_a_song_that_says_its_low_notes_are_intended_is_quiet
    low = Part.new(notes: [Note.new(at: 0, key: 27)])
    decoded = RubyGBA::Audio::Score.new(parts: [low], low_notes_intended: true)

    refute_match(/39 Hz/, warnings { songs(:music, { cave: decoded }).play :cave })
  end

  def test_a_song_block_names_the_part_by_its_name
    said = warnings do
      song(:rumble) { voice(:bass) { note 40, :quarter } }
      play_song :rumble
    end

    assert_match(/The part :bass of the song :rumble plays a note at 40 Hz/, said)
  end
end

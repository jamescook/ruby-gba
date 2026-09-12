# frozen_string_literal: true

require "test_helper"

require "stringio"

# The music looks at one note of each part a frame: due, it plays and the part moves on; not due,
# nothing. So a part's notes must start on later and later frames, inside the song — a note that
# does not is never due, and the part goes silent there until the song starts over. The build
# refuses such a song and says which part, and where.
class TestNoteNeverPlaysGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::NoteNeverPlays

  def tune(events, total_frames: 60)
    song(:tune, total_frames: total_frames, voices: [RubyGBA::Music::Part.new(events: events)])
  end

  def detect(events, **opts) = Check.new.detect(program(tune(events, **opts)))

  # WHY IT IS WORTH REFUSING: a second note on the same frame stops the part, and the notes after
  # it are never heard.
  def test_a_second_note_on_one_frame_silences_the_rest_of_the_part
    i = Reference.new.run(program(enable_sound, tune([[0, 262], [0, 330], [12, 392]]), play_song(:tune),
                                  loop_(wait_vblank)), frames: 30)
    heard = i.audio.select { |entry| entry[0] == :note }.map(&:last)

    assert_includes heard, 262
    refute_includes heard, 392, "the note after the pair never plays"
  end

  def test_two_notes_on_one_frame_stop_the_build
    findings = detect([[0, 262], [12, 330], [12, 392]])

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/same frame, 0\.2 seconds into the song/, findings.first.message)
  end

  def test_a_note_before_the_one_ahead_of_it_is_out_of_order
    assert_match(/time order/, detect([[12, 262], [6, 330]]).first.message)
  end

  def test_a_note_before_the_song_starts
    assert_match(/before the song starts/, detect([[-1, 262]]).first.message)
  end

  def test_a_note_at_the_end_of_the_song_is_never_reached
    assert_match(/only 1 second long/, detect([[0, 262], [60, 330]]).first.message)
  end

  def test_notes_in_order_inside_the_song_are_quiet
    assert_empty detect([[0, 262], [12, 330], [30, 0], [59, 392]])
  end

  # A song block makes one when a note is shorter than a frame: at a tempo this fast a sixteenth
  # rounds to nothing, and the next note lands on the same frame.
  def test_a_note_shorter_than_a_frame_in_a_song_block_stops_the_build
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("TOOFAST", code: "ZFST", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        song :racing do
          tempo 2000
          note :C4, :sixteenth
          note :E4, :quarter
        end
        play_song :racing
        game_loop { wait_vblank }
      end
    end

    assert_match(/The first part of the song :racing has two notes that start on the same frame/, err.string)
    assert_match(/tempo slower/, err.string)
  end
end

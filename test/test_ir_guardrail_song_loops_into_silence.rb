# frozen_string_literal: true

require "test_helper"

require "stringio"

# A song with an introduction plays it once, then repeats from its loop point. When no part plays
# a note from the loop point to the end, that repeat is silence: the music stops after its first
# time through. The build refuses such a song and says where it loops from.
class TestSongLoopsIntoSilenceGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::SongLoopsIntoSilence
  Score = RubyGBA::Score

  # A second long, looping from frame 24 — 0.4 seconds in.
  def tune(*parts, loop_frame: 24)
    song(:tune, total_frames: 60, loop_frame: loop_frame,
                voices: parts.map { |events| RubyGBA::Music::Part.new(events: events) })
  end

  def detect(*parts, **opts) = Check.new.detect(program(tune(*parts, **opts)))

  # A note that stops before the loop point, and nothing after it.
  INTRO_ONLY = [[0, 262], [12, 0]].freeze

  # WHY IT IS WORTH REFUSING: the introduction is heard once, and then nothing, however long the
  # game plays the song.
  def test_the_introduction_plays_once_and_then_nothing
    i = Reference.new.run(program(enable_sound, tune(INTRO_ONLY), play_song(:tune), loop_(wait_vblank)),
                          frames: 200)
    heard = i.audio.select { |entry| entry[0] == :note }.map(&:last)

    assert_equal [262, 0], heard
  end

  def test_a_loop_with_no_note_after_it_stops_the_build
    findings = detect(INTRO_ONLY)

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/loops from 0\.4 seconds into the song/, findings.first.message)
  end

  # --- what counts as something to repeat ---

  # A note held across the loop point is sounded again there every time round, so it is the
  # repeat, even with no note starting after the loop point.
  def test_a_note_held_across_the_loop_point_is_something_to_repeat
    assert_empty detect([[0, 262], [40, 0]])
  end

  # A song that ends on the note it holds across the loop point carries it on instead.
  def test_a_song_that_ends_on_its_held_note_carries_it_on
    assert_empty detect([[0, 262]])
  end

  def test_one_part_that_rests_through_the_repeat_beside_one_that_plays
    assert_empty detect(INTRO_ONLY, [[30, 330]])
  end

  # --- from each way a song is written ---

  def test_a_score_is_told_which_word_to_change
    err = StringIO.new
    intro = Score::Part.new(notes: [Score::Note.new(at: 0, key: :C4, length: 12)])
    score = Score.new(parts: [intro], tempo: 150, length: 72, loop_from: 24) # a tick is a frame
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("SILENT", code: "ZSIL", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        music = songs :music, [score]
        game_loop { music.play 0 }
      end
    end

    assert_match(/Song 0 of :music loops from 0\.4 seconds/, err.string)
    assert_match(/`loop_from:`/, err.string)
  end

  def test_a_song_block_that_marks_its_loop_before_nothing_but_a_rest
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("SILENT", code: "ZSIL", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        song :fanfare do
          tempo 150 # a quarter is 24 frames
          note :C4, :quarter
          loop_from_here
          rest :whole
        end
        play_song :fanfare
        game_loop { wait_vblank }
      end
    end

    assert_match(/The song :fanfare loops from 0\.4 seconds/, err.string)
    assert_match(/`loop_from_here`/, err.string)
  end
end

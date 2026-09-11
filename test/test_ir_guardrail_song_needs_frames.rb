# frozen_string_literal: true

require "test_helper"

require "stringio"

# A song in a program that never waits for the screen never plays: the tune is moved on at the
# moment the screen finishes a picture, and a program with no wait has no such moments. Advisory,
# like the other "no frames to run on" warnings — the build still produces a ROM.
class TestSongNeedsFramesGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::SongNeedsFrames

  def tune
    song(:tune, events: [[0, 262]], total_frames: 4)
  end

  def test_a_song_played_with_no_wait_for_the_screen_warns
    findings = Check.new.detect(program(enable_sound, tune, play_song(:tune), halt))

    assert_equal 1, findings.length
    assert findings.first.warning?, "advisory, not a hard error"
    assert_match(/game_loop/, findings.first.message)
  end

  def test_a_song_in_a_game_loop_is_quiet
    assert_empty Check.new.detect(program(enable_sound, tune, loop_(wait_vblank, play_song(:tune))))
  end

  def test_a_song_that_is_written_and_never_played_is_quiet
    assert_empty Check.new.detect(program(enable_sound, tune, halt))
  end

  def test_the_build_says_it_out_loud
    err = StringIO.new
    RubyGBA.build("SILENT", code: "ZSIL", maker: "01", out: StringIO.new, err: err) do
      enable_sound
      song(:tune) { note :C4, :quarter }
      play_song :tune
      halt
    end

    assert_match(/never waits for the screen/, err.string)
  end
end

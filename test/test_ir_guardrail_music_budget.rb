# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The music-cost guardrail: warn (never error) when a single song is long enough
# that its per-frame note-check chain is heavy on its own. Playing a song re-checks
# every note against a frame counter on every frame, so a long tune is real
# recurring work independent of drawing. Advisory: the build still produces a ROM.
class TestMusicBudgetGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::MusicBudget

  # A game that plays an +n+-note song every frame.
  def game_playing(n)
    program(
      display(:bitmap),
      song(:theme, events: Array.new(n) { |i| [i, 440] }, total_frames: n),
      loop_(wait_vblank, play_song(:theme)),
    )
  end

  # A long tune warns, names the song, and explains the per-frame re-check.
  def test_a_long_song_warns_about_per_frame_note_checks
    findings = Check.new.detect(game_playing(300))
    assert_equal 1, findings.length
    assert findings.first.warning?, "the music budget is advisory, not a hard error"
    assert_match(/theme/, findings.first.message)   # names the offending song
    assert_match(/300 notes/, findings.first.message)
    assert_match(/every.*frame/, findings.first.message)
  end

  # An ordinary short tune is quiet.
  def test_a_short_song_is_quiet
    assert_empty Check.new.detect(game_playing(50))
  end

  # No music, nothing to say.
  def test_quiet_when_there_is_no_music
    prog = program(display(:bitmap), loop_(wait_vblank, clear_screen(:black)))
    assert_empty Check.new.detect(prog)
  end

  # A one-shot program that never loops plays the song once, so there's no
  # per-frame chain to warn about even for a long score.
  def test_quiet_without_a_game_loop
    prog = program(
      display(:bitmap),
      song(:theme, events: Array.new(300) { |i| [i, 440] }, total_frames: 300),
      play_song(:theme),
      halt,
    )
    assert_empty Check.new.detect(prog)
  end

  # It's a builtin: it fires in the default validation pass, not just when called
  # directly.
  def test_it_runs_in_the_default_validation_pass
    report = RubyGBA::IR::Guardrails::Validator.new.run(game_playing(300), autofix: false)
    assert(report.warnings.any? { |w| w.check == :music_budget },
           "the music guardrail should be registered as a builtin")
  end
end

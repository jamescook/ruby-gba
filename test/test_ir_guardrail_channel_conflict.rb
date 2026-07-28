# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The channel-conflict guardrail: warn (never error) when a program plays a
# two-part song AND beeps. A two-part song's second part needs the same sound
# voice beeps play on, so the two cut each other off — a silent footgun unless you
# know the console has only so many voices. Advisory: the build still produces a ROM.
class TestChannelConflictGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::ChannelConflict

  def duet
    song(:duet, total_frames: 4, voices: [
      { events: [[0, 262]], duty: :half, volume: 12 },
      { events: [[0, 131]], duty: :half, volume: 8 },
    ])
  end

  def solo
    song(:solo, events: [[0, 262]], total_frames: 4)
  end

  # A two-part song playing alongside a beep warns, names the song, and explains
  # the shared voice.
  def test_a_two_part_song_with_a_beep_warns
    prog = program(enable_sound, duet, loop_(wait_vblank, play_song(:duet), beep(:high)))
    findings = Check.new.detect(prog)
    assert_equal 1, findings.length
    assert findings.first.warning?, "the channel conflict is advisory, not a hard error"
    assert_match(/duet/, findings.first.message)
    assert_match(/beep/, findings.first.message)
  end

  # A one-part song leaves the effect voice free, so beeps are fine.
  def test_a_one_part_song_with_a_beep_is_quiet
    prog = program(enable_sound, solo, loop_(wait_vblank, play_song(:solo), beep(:high)))
    assert_empty Check.new.detect(prog)
  end

  # A two-part song with no beeps anywhere has nothing to collide with.
  def test_a_two_part_song_without_beeps_is_quiet
    prog = program(enable_sound, duet, loop_(wait_vblank, play_song(:duet)))
    assert_empty Check.new.detect(prog)
  end

  # A two-part song that's defined but never played can't conflict with a beep.
  def test_an_unplayed_two_part_song_is_quiet
    prog = program(enable_sound, duet, loop_(wait_vblank, beep(:high)))
    assert_empty Check.new.detect(prog)
  end

  # It's a builtin: it fires in the default validation pass.
  def test_it_runs_in_the_default_validation_pass
    prog = program(enable_sound, duet, loop_(wait_vblank, play_song(:duet), beep(:high)))
    report = RubyGBA::IR::Guardrails::Validator.new.run(prog, autofix: false)
    assert(report.warnings.any? { |w| w.check == :channel_conflict },
           "the channel-conflict guardrail should be registered as a builtin")
  end
end

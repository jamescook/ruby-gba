# frozen_string_literal: true

require "test_helper"

# The channel-conflict guardrail: warn (never error) when a program plays a
# two-part song AND beeps. A two-part song's second part needs the same sound
# voice beeps play on, so the two cut each other off — a silent footgun unless you
# know the console has only so many voices. Advisory: the build still produces a ROM.
class TestChannelConflictGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::ChannelConflict

  def duet
    song(:duet, total_frames: 4, voices: [
      RubyGBA::Music::Part.new(events: [[0, 262]]),
      RubyGBA::Music::Part.new(events: [[0, 131]], volume: 8),
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

  # --- the other two voices the console plays itself ---
  #
  # There is ONE wave voice and ONE noise voice, so a single part on either already shares it
  # with the matching sound effect — where a beep only collides with a song's SECOND square
  # part. Same warning, same reason, and the build still produces a ROM.

  def pad
    song(:pad, total_frames: 4, voices: [RubyGBA::Music::Part.new(events: [[0, 262]], wave: :triangle)])
  end

  def drums
    song(:drums, total_frames: 4, voices: [RubyGBA::Music::Part.new(events: [[0, 262]], noise: true)])
  end

  def test_a_wave_part_with_a_wave_sound_effect_warns
    prog = program(enable_sound, pad, loop_(wait_vblank, play_song(:pad), wave(shape: :sine, frequency: 440, volume: :full)))
    findings = Check.new.detect(prog)

    assert_equal 1, findings.length
    assert findings.first.warning?
    assert_match(/the wave voice/, findings.first.message)
    assert_match(/`wave`/, findings.first.message)
  end

  def test_a_noise_part_with_a_noise_hit_warns
    prog = program(enable_sound, drums, loop_(wait_vblank, play_song(:drums), noise(:kick)))
    findings = Check.new.detect(prog)

    assert_equal 1, findings.length
    assert_match(/the noise voice/, findings.first.message)
    assert_match(/`noise`/, findings.first.message)
  end

  # A part on one of them is quiet while nothing else plays that voice — and a beep does not
  # reach either, so it says nothing about them.
  def test_a_wave_part_with_only_beeps_is_quiet
    prog = program(enable_sound, pad, loop_(wait_vblank, play_song(:pad), beep(:high)))

    assert_empty Check.new.detect(prog)
  end

  def test_a_noise_part_with_no_noise_hits_is_quiet
    prog = program(enable_sound, drums, loop_(wait_vblank, play_song(:drums)))

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

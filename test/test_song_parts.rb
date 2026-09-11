# frozen_string_literal: true

require "test_helper"

require "stringio"

# A SONG OF MANY PARTS. The console has two square-wave voices for music, and a song's other
# parts play recorded instruments through the mixer — so a tune is not held to two parts, it is
# held to two square-wave parts and as many recorded ones as the mixer has voices. The music a
# game being built on the framework reads out of a retail cartridge wants seven to nine, and
# twelve at the most, with the game's own sounds beside them.
class TestSongParts < Minitest::Test
  NOTES = RubyGBA::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE
  VOICES = RubyGBA::Sound::MIXER_VOICES

  # Twelve recorded parts, one note each, all on the downbeat — a chord twelve voices wide.
  CHORD = %i[C4 Cs4 D4 Ds4 E4 F4 Fs4 G4 Gs4 A4 As4 B4].freeze

  # A song of two square-wave parts and a recorded part for each of +chord+.
  def song_of(chord)
    lambda do
      instrument :organ, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :big do
        voice(:lead) { note :C5, :whole }
        voice(:bass) { note :C3, :whole }
        chord.each_with_index { |pitch, n| voice(:"pad_#{n}", plays: :organ) { note pitch, :whole } }
      end
    end
  end

  # The fourteen-part song, and a sound of the game's own sounding beside it the whole time.
  def fourteen_part_game
    tune = song_of(CHORD)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instance_exec(&tune)
      hum = sample :hum, pcm: [20, -20] * 4000, rate: 8000
      hum.play(loop: true)
      play_song :big
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    b.program
  end

  def test_every_part_sounds_on_the_downbeat_beside_the_games_own_sound
    i = Reference.new.run(fourteen_part_game, frames: 3)

    downbeat = i.audio.select { |entry| entry[0] == :note }.map(&:last)
    assert_equal [NOTES[:C5], NOTES[:C3], *CHORD.map { |pitch| NOTES[pitch] }], downbeat
    assert_equal [:hum] + ([:organ] * 12), i.active_samples, "the game's sound, and twelve recorded parts at once"
  end

  def test_the_console_sounds_all_twelve_recorded_parts_at_their_pitches_beside_the_games_sound
    console = assert_emulator_loads_rom(assemble_rom(fourteen_part_game, name: "SONG14"), frames: 6)
    organ = console.voices.select { |voice| voice.sample == :organ }.map(&:step).sort
    expected = CHORD.map { |pitch| (NOTES[pitch].to_f / NOTES[:C4] * STEP_ONE).round }

    assert_equal 12, organ.size, "twelve recorded parts sounding (#{console.voices.inspect})"
    organ.zip(expected).each { |got, want| assert_in_delta want, got, 2 }
    assert_equal [:hum], console.voices.map(&:sample) - [:organ], "...and the game's own sound with them"
    assert console.sound?
  end

  # --- what cannot be had, said plainly ---

  # More recorded parts than the mixer has voices stops the build (the check itself is
  # test_ir_guardrail_song_too_many_parts.rb) — and only that is said, not also the warning about
  # keeping every voice, which is about a song that fits.
  def test_more_recorded_parts_than_the_mixer_has_voices_is_said_once
    err = StringIO.new
    too_many = VOICES + 1
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("SONGOVER", code: "ZSNO", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        instrument :organ, pcm: [60, -60] * 400, rate: 8000, note: :C4
        song(:big) { too_many.times { |n| voice(:"pad_#{n}", plays: :organ) { note :C4, :quarter } } }
        zap = sample :zap, pcm: [60, -60] * 400, rate: 8000
        play_song :big
        game_loop { pressed(:a).then { zap.play } }
      end
    end

    assert_match(/#{too_many} parts that play an instrument/, err.string)
    refute_match(/never play/, err.string)
  end

  # A song with as many recorded parts as there are voices builds without a word: the voices are
  # shared, so its notes take them only while they sound, and a sound of the game's own gets one
  # whenever a part rests.
  def test_a_song_as_wide_as_the_mixer_is_no_trouble_to_a_game_with_sounds_of_its_own
    tune = song_of(Array.new(VOICES) { :C4 })
    err = StringIO.new
    RubyGBA.build("SONGALL", code: "ZSNA", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      enable_sound
      instance_exec(&tune)
      zap = sample :zap, pcm: [60, -60] * 400, rate: 8000
      play_song :big
      game_loop { pressed(:a).then { zap.play } }
    end

    assert_empty err.string
  end

  # --- what it costs is measured, by name ---

  def test_the_profile_shows_what_the_music_costs
    tune = song_of(CHORD)
    rom = RubyGBA.build("SONGCOST", code: "ZSNC", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      enable_sound
      instance_exec(&tune)
      play_song :big
      game_loop { wait_vblank }
    end
    result = RubyGBA::Profiler.run(rom, frames: 30, picture: false)
    shares = result.lines.to_h { |line| [line.name, line.share] }

    assert_operator shares.fetch(:__mix_routine, 0), :>, 0, "mixing the eight parts is measured (#{shares.inspect})"
    assert_operator shares.fetch(:__interrupt, 0), :>, 0, "...and so is the player that starts their notes"
  end
end

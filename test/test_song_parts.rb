# frozen_string_literal: true

require "test_helper"

require "stringio"

# A SONG OF MANY PARTS. The console has two square-wave voices for music, and a song's other
# parts play recorded instruments through the mixer — so a tune is not held to two parts, it is
# held to what is really there: two square-wave parts and as many recorded ones as the mixer has
# voices. The tunes that want this want seven or eight.
class TestSongParts < Minitest::Test
  NOTES = RubyGBA::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE

  # Eight recorded parts, one note each, all on the downbeat — a chord eight voices wide.
  CHORD = %i[C4 D4 E4 F4 G4 A4 B4 C5].freeze

  # Ten parts: two square-wave parts and the eight above.
  def ten_part_song
    chord = CHORD
    lambda do
      instrument :organ, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :big do
        voice(:lead) { note :C5, :whole }
        voice(:bass) { note :C3, :whole }
        chord.each { |pitch| voice(:"pad_#{pitch}", plays: :organ) { note pitch, :whole } }
      end
    end
  end

  def ten_part_game
    tune = ten_part_song
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instance_exec(&tune)
      play_song :big
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    b.program
  end

  def test_every_part_sounds_on_the_downbeat
    i = Reference.new.run(ten_part_game, frames: 3)

    downbeat = i.audio.select { |entry| entry[0] == :note }.map(&:last)
    assert_equal [NOTES[:C5], NOTES[:C3], *CHORD.map { |pitch| NOTES[pitch] }], downbeat
    assert_equal [:organ] * 8, i.active_samples, "the eight recorded parts are eight voices at once"
  end

  def test_the_console_sounds_all_eight_recorded_parts_at_their_pitches
    console = assert_emulator_loads_rom(assemble_rom(ten_part_game, name: "SONGTEN"), frames: 6)
    steps = console.voices.map(&:step).sort
    expected = CHORD.map { |pitch| (NOTES[pitch].to_f / NOTES[:C4] * STEP_ONE).round }

    assert_equal 8, steps.size, "eight voices sounding (#{console.voices.inspect})"
    steps.zip(expected).each { |got, want| assert_in_delta want, got, 2 }
    assert console.sound?
  end

  # --- what cannot be had, said plainly ---

  def test_more_recorded_parts_than_the_mixer_has_voices_is_a_friendly_error
    ctx = RubyGBA::Music::SongContext.new
    err = assert_raises(ArgumentError) do
      ctx.instance_eval do
        9.times { |n| voice(:"pad_#{n}", plays: :organ) { note :C4, :quarter } }
      end
    end
    assert_match(/at most 8/, err.message)
  end

  # A song whose recorded parts take every voice of the mixer leaves none for the game's own
  # sounds — for the whole game, since which voices the music keeps is settled when it is built.
  # Nothing would crash and the sounds would simply never play, so the build says so.
  def test_music_that_keeps_every_voice_warns_a_game_with_sounds_of_its_own
    tune = ten_part_song
    err = StringIO.new
    RubyGBA.build("SONGALL", code: "ZSNA", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      enable_sound
      instance_exec(&tune)
      zap = sample :zap, pcm: [60, -60] * 400, rate: 8000
      play_song :big
      game_loop { pressed(:a).then { zap.play } }
    end

    assert_match(/:big/, err.string)
    assert_match(/never play/, err.string)
  end

  def test_music_that_leaves_voices_over_says_nothing
    err = StringIO.new
    RubyGBA.build("SONGSOME", code: "ZSNS", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      enable_sound
      instrument :organ, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song(:small) { voice(:pad, plays: :organ) { note :C4, :whole } }
      zap = sample :zap, pcm: [60, -60] * 400, rate: 8000
      play_song :small
      game_loop { pressed(:a).then { zap.play } }
    end

    refute_match(/never play/, err.string)
  end

  # --- what it costs is measured, by name ---

  def test_the_profile_shows_what_the_music_costs
    tune = ten_part_song
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

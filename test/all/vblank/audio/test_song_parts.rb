# frozen_string_literal: true

require "test_helper"

require "stringio"

# A SONG OF MANY PARTS. The console has two square-wave voices for music, and a song's other
# parts play recorded instruments through the mixer — so a tune is not held to two parts, it is
# held to two square-wave parts and as many recorded ones as the mixer has voices. The music a
# game being built on the framework reads out of a retail cartridge wants seven to nine, and
# twelve at the most, with the game's own sounds beside them.
#
# What the Advance's cartridge sounds, and what its mixing costs, is in
# test/lowering/gba/vblank/audio/test_song_parts_cartridge.rb.

# The songs both files build.
module SongPartsGames
  NOTES = Ractor.make_shareable(VBlank::Audio::Music::NOTE_FREQUENCIES)
  STEP_ONE = VBlank::IR::Backends::GBA::Mixer::STEP_ONE
  VOICES = VBlank::Audio::Sound::MIXER_VOICES

  # Twelve recorded parts, one note each, all on the downbeat — a chord twelve voices wide.
  CHORD = %i[C4 Cs4 D4 Ds4 E4 F4 Fs4 G4 Gs4 A4 As4 B4].freeze

  # A song of two square-wave parts and a recorded part for each of +chord+.
  private def song_of(chord)
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
  private def fourteen_part_game
    tune = song_of(CHORD)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instance_exec(&tune)
      hum = sample :hum, pcm: [20, -20] * 4000, rate: 8000
      hum.play(loop: true)
      play_song :big
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Four parts on one instrument, no square part, no sound of the game's: if the recordings are
  # silent there is nothing left to hear.
  private def recorded_parts_only_game
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :organ, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :pads do
        %i[C4 E4 G4 C5].each_with_index { |pitch, n| voice(:"pad_#{n}", plays: :organ) { note pitch, :whole } }
      end
      play_song :pads
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end

class TestSongParts < Minitest::Test
  include SongPartsGames

  # --- what cannot be had, said plainly ---

  # More recorded parts than the mixer has voices stops the build (the check itself is
  # test_ir_guardrail_song_too_many_parts.rb) — and only that is said, not also the warning about
  # keeping every voice, which is about a song that fits.
  def test_more_recorded_parts_than_the_mixer_has_voices_is_said_once
    err = StringIO.new
    too_many = VOICES + 1
    assert_raises(VBlank::ROMError) do
      VBlank.build("SONGOVER", console: :gba, code: "ZSNO", maker: "01", out: StringIO.new, err: err) do
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
    VBlank.build("SONGALL", console: :gba, code: "ZSNA", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      enable_sound
      instance_exec(&tune)
      zap = sample :zap, pcm: [60, -60] * 400, rate: 8000
      play_song :big
      game_loop { pressed(:a).then { zap.play } }
    end

    assert_empty err.string
  end
end

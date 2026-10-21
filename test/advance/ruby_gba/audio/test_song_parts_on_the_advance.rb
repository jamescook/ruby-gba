# frozen_string_literal: true

require "test_helper"

require "stringio"

# THE TESTS OF ruby_gba/audio/test_song_parts.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A SONG OF MANY PARTS. The console has two square-wave voices for music, and a song's other
# parts play recorded instruments through the mixer — so a tune is not held to two parts, it is
# held to two square-wave parts and as many recorded ones as the mixer has voices. The music a
# game being built on the framework reads out of a retail cartridge wants seven to nine, and
# twelve at the most, with the game's own sounds beside them.
class TestSongPartsOnTheAdvance < Minitest::Test
  NOTES = RubyGBA::Audio::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE
  VOICES = RubyGBA::Audio::Sound::MIXER_VOICES

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
    b.finalize_program
    b.program
  end

  # --- a recorded part on its own, with NOTHING sounding beside it ---

  # THE TEST THAT WAS MISSING, and the reason a real bug lived here unnoticed: every hardware
  # test above has something ELSE making a noise at the same time — two square-wave parts and a
  # looping hum — so `sound?` was satisfied by the square wave while the recorded parts put out
  # nothing at all, and the twelve voices were read off the voice TABLE, which is bookkeeping
  # rather than audio. A tune whose melody is silent passes every one of them.
  #
  # So this is four parts on one instrument, no square part, no sound of the game's: if the
  # recordings are silent there is nothing left to hear.
  private def recorded_parts_only_game
    b = Builder.new
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

  # The interpreter plays it too, so the two backends agree about the same program.
  def test_the_interpreter_plays_a_song_of_recorded_parts_alone
    i = game_player.run(recorded_parts_only_game, frames: 3)

    assert_equal [:organ] * 4, i.active_samples
    assert_equal %i[C4 E4 G4 C5].map { |pitch| NOTES[pitch] },
                 i.audio.select { |entry| entry[0] == :note }.map(&:last)
  end

  # --- what cannot be had, said plainly ---

  # --- what it costs is measured, by name ---

end

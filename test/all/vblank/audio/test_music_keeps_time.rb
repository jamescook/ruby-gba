# frozen_string_literal: true

require "test_helper"

# The scale game and how to read which notes a run heard, shared with the interpreter's tests of
# a late pass (test/interpreter/vblank/audio/test_music_keeps_time_interpreter.rb).
module MusicKeepsTimeGames
  include SharedConstants

  C4 = VBlank::Audio::Music::NOTE_FREQUENCIES[:C4]
  E4 = VBlank::Audio::Music::NOTE_FREQUENCIES[:E4]
  G4 = VBlank::Audio::Music::NOTE_FREQUENCIES[:G4]

  private def notes(interpreter)
    interpreter.audio.select { |entry| entry[0] == :note }.map(&:last)
  end

  # A note every ten frames — C4, E4, G4 — so which notes a run heard says how far into the tune
  # it got. The block is the loop's body, handed how many passes have run.
  private def scale_game(&loop_body)
    loop_body ||= proc { play_song :scale }
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :scale do
        tempo 360 # a quarter is ten frames
        note :C4, :quarter
        note :E4, :quarter
        note :G4, :quarter
      end
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        instance_exec(pass, &loop_body)
      end
    end
    b.finalize_program
    b.program
  end
end

# A TUNE KEEPS ITS OWN TIME, whatever the game does, and so does a recording the game plays —
# the same promise the mixer makes
# (test_mixer_keeps_time.rb), for the same reason. A tempo is a fact about the clock on the
# wall, not about how long the game took to think, so a game too heavy for a frame still plays
# its music at the speed it was written.
#
# Which is why `play_song` names the tune that is playing rather than stepping it along: a tune
# stepped once per pass of the game loop plays at half speed in a game that takes two frames a
# pass, and at no speed at all in a frame whose branch skipped the call.
#
# A pass told to take several frames is something only the interpreter can be told, so those
# tests are in test/interpreter/vblank/audio/test_music_keeps_time_interpreter.rb; the Advance's
# cartridge, genuinely late and heard in the emulator, is in
# test/lowering/gba/vblank/audio/test_music_keeps_time_cartridge.rb.
class TestMusicKeepsTime < Minitest::Test
  include MusicKeepsTimeGames

  def test_a_tune_named_only_on_some_frames_keeps_its_tempo
    every_frame = game_player.run(scale_game, frames: 30)
    every_other = game_player.run(scale_game { |pass| (pass % 2 == 0).then { play_song :scale } }, frames: 30)

    assert_equal notes(every_frame), notes(every_other),
                 "a tune that is named on half the frames is still playing on the other half"
  end

  def test_naming_the_tune_twice_in_one_frame_is_the_same_as_once
    once = game_player.run(scale_game, frames: 30)
    twice = game_player.run(scale_game { play_song :scale; play_song :scale }, frames: 30)

    assert_equal notes(once), notes(twice)
  end

  # --- switching tunes, which is what a jukebox or a scene change does ---

  private def two_tunes_game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :first do
        tempo 360
        note :C4, :quarter
        note :E4, :quarter
        note :G4, :quarter
      end
      song :second do
        tempo 360
        note :A4, :quarter
      end
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        # the first tune, then the second from pass 16, then back to the first from pass 22
        ((pass >= 16) & (pass < 22)).then { play_song :second }.else { play_song :first }
      end
    end
    b.finalize_program
    b.program
  end

  def test_coming_back_to_a_tune_starts_it_from_the_beginning
    heard = notes(game_player.run(two_tunes_game, frames: 30))

    # C4 and E4 (the first tune reaches its second note), A4 (the second), then the first tune
    # again FROM ITS DOWNBEAT — not from wherever it had got to when it was left.
    assert_equal [C4, E4, VBlank::Audio::Music::NOTE_FREQUENCIES[:A4], C4], heard
  end

  def test_stopping_the_music_silences_it_and_starting_again_starts_over
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :scale do
        tempo 360
        note :C4, :quarter
        note :E4, :quarter
      end
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        ((pass >= 5) & (pass < 8)).then { stop_music }.else { play_song :scale }
      end
    end
    b.finalize_program
    i = game_player.run(b.program, frames: 12)

    assert_equal [:note, :stop_music, :note], i.audio.filter_map { |e| e[0] if %i[note stop_music].include?(e[0]) },
                 "the tune stops once, then starts over from its downbeat"
    assert_equal [C4, C4], notes(i)
  end

  # Saying "no music" while none is playing does nothing at all. A game that writes it every frame
  # a setting is off — pong's music row does — must not keep reaching for the sound hardware,
  # because the voice it would silence is the one its sound effects play on.
  def test_saying_no_music_while_none_plays_does_nothing
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :scale do
        note :C4, :quarter
      end
      game_loop { stop_music }
    end
    b.finalize_program
    i = game_player.run(b.program, frames: 10)

    assert_empty i.audio.select { |e| e[0] == :stop_music }
  end
end

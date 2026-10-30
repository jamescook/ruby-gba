# frozen_string_literal: true

require "test_helper"
require "speakers"
require "all/vblank/audio/test_song_pan"

# A SONG'S SIDES ON THE ADVANCE'S CARTRIDGE, heard in the emulator: which speaker each voice
# plays from. The sides every run plays, read from the log, are in
# test/all/vblank/audio/test_song_pan.rb.
class TestSongPanCartridge < Minitest::Test
  include SongPanGames
  include Speakers

  # THE CARTRIDGE, heard in the emulator: each voice from its own speaker alone, the drums and the
  # wave voice included, and a part that says nothing from both.
  def test_the_cartridge_plays_each_part_from_its_own_speaker
    require_emulator!
    game = song_game do
      voice(:lead) { |v| v.pan :left; v.note :C5, :whole }
      voice(:harmony) { |v| v.pan :right; v.note :E4, :whole }
      voice(:bass, plays: :wave) { |v| v.pan :left; v.note :C3, :whole }
      voice(:drums, plays: :noise) { |v| v.note :C4, :whole, decay: :none }
    end
    { square1: :left, square2: :right, wave: :left, noise: :both }.each do |voice, side|
      assert_heard_from side, loudest_on_each_side(game, voice, frames: 40, from: 10), voice
    end
  end

  # THE GAME'S OWN SOUND — a beep, a hit on the noise voice, a tone on the wave voice — plays from
  # both speakers, on the voice a song's note left at the right.
  def test_the_games_own_sound_after_a_panned_note_plays_from_both_speakers
    require_emulator!
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150
        voice(:lead) { |v| v.rest :whole }
        voice(:harmony) { |v| v.pan :right; v.note :E4, :whole }
        voice(:pad, plays: :wave) { |v| v.pan :right; v.note :C3, :whole }
        voice(:drums, plays: :noise) { |v| v.pan :right; v.note :C4, :whole, decay: :none }
      end
      play_song :tune
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 40).then do
          beep 880, decay: :none
          noise :kick, decay: :none
          wave :sawtooth, :A3, volume: :half
        end
        wait_vblank
      end
    end
    b.finalize_program

    %i[square2 wave noise].each do |voice|
      assert_heard_from :both, loudest_on_each_side(b.program, voice, frames: 60, from: 45), voice
    end
  end
end

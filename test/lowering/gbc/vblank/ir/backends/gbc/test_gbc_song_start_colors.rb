# frozen_string_literal: true

require "test_helper"

# THE FRAME A SONG STARTS ON SHOWS ITS COLOURS WHOLE. A song's first frame of music is the long one:
# every part's first note is read, and a part on the wave voice writes its waveform. The colours a
# pass changes are copied to the console in the blank after it, and the music's frame used to be
# played first there, so on a song's first frame the colours went out part way down the screen and
# the frame showed torn. Most games start their music as a screen fades in. The run checks every
# frame's picture against the interpreter's, every row of it.
class TestGBCSongStartColors < Minitest::Test
  private def fade_in_with_a_song
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:block, "#" => :white) { "########\n" * 8 }
      tiles :set, "#" => :block
      background :field, tiles: :set, map: Array.new(18) { "#" * 20 }
      enable_sound
      song :tune do
        tempo 120
        voice(:low, plays: :wave) { |v| v.note :A3, :whole }
        voice(:lead) { |v| v.note :C5, :whole }
        voice(:harmony) { |v| v.note :E5, :whole }
        voice(:drums, plays: :noise) { |v| v.note :C4, :quarter }
      end
      # ...beside a sound effect of four parts started with it, and a music volume, as a game's
      # title has: each adds to the frame's music.
      score = VBlank::Audio::Score
      parts = [nil, nil, :wave, :noise].map do |voice|
        score::Part.new(plays: voice, notes: [score::Note.new(at: 0, key: :A4), score::Note.new(at: 1, key: :C5)])
      end
      sfx = sound_effects :sfx, { chime: score.new(tempo: 150, length: 60, parts: parts) }
      music_volume 60
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 5).then do
          play_song :tune
          sfx.play :chime
          fade :black, 50
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_the_frame_a_song_starts_on_shows_its_new_colours_on_every_row
    i = game_player.run(fade_in_with_a_song, frames: 8)

    refute_equal 0, i.screen.pixel(80, 130), "the fade's step, at the bottom of the screen"
  end
end

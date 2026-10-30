# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT SOUND EFFECTS COST ON A FRAME NONE OF THEM IS PLAYING, which is nearly every frame of a game.
#
# The routine that answers the display walks the table of effects on each frame one of them has
# something to do. On the others it skips the table, so a game pays the same on a quiet frame for
# three effects as for thirty: a game that moved its shots into a group of effects paid for that on
# every frame of walking about, shots fired or not.
class TestQuietEffectsCost < Minitest::Test
  Score = VBlank::Audio::Score

  # Instructions a frame for a game with +count+ sound effects that it never plays, beside a song.
  private def instructions_a_frame(count)
    notes = [Score::Note.new(at: 0, key: :C5)]
    effects = Array.new(count) { Score.new(tempo: 150, parts: [Score::Part.new(notes: notes)]) }
    song = Score.new(tempo: 150, length: 48, parts: [Score::Part.new(notes: [Score::Note.new(at: 0, key: :C4)])])
    rom = VBlank.build("QUIETFX", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, effects
      music = songs :music, [song]
      game_loop do
        music.play 0
        pressed(:a).then { sfx.play 0 }
      end
    end
    VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false).samples_per_frame
  end

  def test_thirty_quiet_effects_cost_a_frame_what_three_do
    assert_in_delta instructions_a_frame(3), instructions_a_frame(30), 4
  end
end

# frozen_string_literal: true

require "test_helper"
require "sound_comparison"

# THE COLOR CARTRIDGE'S SOUND, for a wobble its music player moves a frame at a time: the run's log
# says the player made each move, but not that the voice was told. Read off the cartridge's own
# sound, a voice holds its note's pitch, then the pitch above and the pitch below by turns. The
# voice is tuned by the same pitch number as the Advance's, so the pitches are the ones the Advance
# cartridge holds for the same notes (test/vblank/ir/backends/native/test_native_tones.rb).
class TestGBCTones < Minitest::Test
  include SoundComparison

  private def color_program(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # Every pitch +voice+ holds still for three frames running over +frames+ frames, to the nearest Hz
  # — from frame +from+ on, when that is given.
  private def held_pitches(program, voice, frames:, from: 1)
    heard = console_voice(program, voice, frames: frames)
    (from...(heard.frame_count - 1)).filter_map { |index| heard.held_note(index)&.pitch&.round }.uniq
  end

  # A beep takes the second square voice from a song note wobbling there: the player bends no beep.
  def test_a_beep_over_a_wobbling_note_is_not_bent
    program = color_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { |v| v.note :C5, :whole }
        voice(:harmony) { |v| v.vibrato depth: 15, speed: 6; v.note :E4, :whole }
      end
      play_song :tune
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 20).then { beep 880, duty: :half, decay: :none, volume: 12 }
      end
    end

    assert_equal [880], held_pitches(program, :square2, frames: 80, from: 50).map { |hz| hz.round(-1) }.uniq
  end

  def test_a_square_note_and_a_wave_note_wobble
    program = color_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { |v| v.vibrato depth: 15, speed: 8, after: 10; v.note :A4, :whole }
        voice(:pad, plays: :wave) { |v| v.vibrato depth: 15, speed: 8; v.note :E4, :whole }
      end
      play_song :tune
      game_loop {}
    end

    square = held_pitches(program, :square1, frames: 60)
    assert_includes square, 440, "A4 at its own pitch, through the wait"
    assert_includes square, 452, "eight steps above"
    assert_includes square, 430, "seven below"
    wave = held_pitches(program, :wave, frames: 60)
    assert_includes wave, 343, "E4 on the wave voice, eight steps above"
    assert_includes wave, 318, "...and seven below"
  end

  def test_a_sound_effects_note_wobbles
    score = VBlank::Audio::Score
    siren = score.new(tempo: 120, parts: [score::Part.new(vibrato: { depth: 14, speed: 8 },
                                                          notes: [score::Note.new(at: 0, key: :C5, length: 72)])])
    program = color_program do
      enable_sound
      sfx = sound_effects :sfx, { siren: siren }
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 4).then { sfx.play :siren }
      end
    end

    pitches = held_pitches(program, :square1, frames: 60)
    assert_includes pitches, 537, "C5, seven steps above"
    assert_includes pitches, 508, "...and seven below"
  end
end

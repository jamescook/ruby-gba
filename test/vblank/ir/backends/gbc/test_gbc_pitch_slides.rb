# frozen_string_literal: true

require "test_helper"

# A SONG'S NOTES THAT SLIDE THEIR PITCH, as the Color's cartridge tells its first square voice. The
# voice keeps how its note slides in its sweep register (NR10): the 128ths of a second each step
# waits in bits 4 to 6, 8 when it slides down, and the shift under that. Whether the song plays as
# the interpreter plays it is test/vblank/audio/test_song_pitch_slides.rb's, on every lowering; this
# is what reaches the register.
class TestGBCPitchSlides < Minitest::Test
  H = VBlank::Console::GBCHardware

  private def color_game(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      instance_eval(&block)
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Read a few frames in: the Color's boot takes some before the game's first.
  private def nr10_after(program, frames: 12)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "SLIDES")
    VBlank::Diagnostics::Verifier.new(rom, frames: frames).mem8(H::NR10) & 0x7F
  end

  def test_the_first_square_voice_is_told_how_its_note_slides
    program = color_game do
      song(:tune) do
        voice(:lead) { |v| v.note :C5, :whole, slide_down: :slow }
        voice(:bass) { |v| v.note :C3, :whole }
      end
      play_song :tune
    end

    assert_equal (7 << 4) | 8 | 5, nr10_after(program)
  end

  # A game whose only slide word is `:none` slides nothing, and is the cartridge it was without it:
  # no byte more a note, no more of the player.
  def test_saying_no_slide_builds_the_same_cartridge
    said = color_game do
      song(:tune) { voice(:lead) { |v| v.note :C5, :whole, slide_down: :none } }
      play_song :tune
    end
    plain = color_game do
      song(:tune) { voice(:lead) { |v| v.note :C5, :whole } }
      play_song :tune
    end
    cartridge = ->(program) { VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "SLIDES").bytes }

    assert_equal cartridge.call(plain), cartridge.call(said)
  end

  # A sound effect's notes are told the same way, through the same routine.
  def test_a_sound_effects_note_is_told_how_it_slides
    score = VBlank::Audio::Score
    zap = score.new(tempo: 120, parts: [score::Part.new(notes: [
                                          score::Note.new(at: 0, key: :E5, length: 48, slide_up: { every: 2, shift: 6 }),
                                        ])])
    program = color_game do
      sfx = sound_effects :sfx, { zap: zap }
      sfx.play :zap
    end

    assert_equal (2 << 4) | 6, nr10_after(program)
  end
end

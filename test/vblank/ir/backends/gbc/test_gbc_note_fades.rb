# frozen_string_literal: true

require "test_helper"

# A SONG'S NOTES THAT FADE OR SWELL, as the Color's cartridge tells its voices. Each square and
# noise voice keeps how its note fades in the low four bits of its volume register (NR12, NR22,
# NR42), under the volume it starts at: the step, and 8 more when it swells. Whether the song plays
# as the interpreter plays it is test/vblank/audio/test_song_note_fades.rb's, on every lowering;
# this is what reaches the registers.
class TestGBCNoteFades < Minitest::Test
  H = VBlank::Console::GBCHardware

  private def color_program(&song)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune, &song)
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Read a few frames in: the Color's boot takes some before the game's first.
  private def registers_after(program, frames: 12)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "FADES")
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: frames)
    [H::NR12, H::NR22, H::NR42].map { |register| reader.mem8(register) }
  end

  def test_each_voice_is_told_how_its_note_fades
    nr12, nr22, nr42 = registers_after(color_program do
      voice :lead do |v|
        v.decay :slow
        v.note :C4, :whole
      end
      voice :pad do |v|
        v.volume 0
        v.swell :fast
        v.note :G4, :whole
      end
      voice :drums, plays: :noise do |v|
        v.decay :fast
        v.note :C2, :quarter, swell: 2
      end
    end)

    assert_equal 0xC5, nr12, "the lead starts at 12 and steps down every five 64ths of a second"
    assert_equal 0x09, nr22, "the pad starts at nothing and steps up every 64th"
    assert_equal 0xCA, nr42, "the drum's own note swells, where the part's hits would fade"
  end

  # A sound effect's notes are told the same way, through the same routine.
  def test_a_sound_effects_note_is_told_how_it_fades
    score = VBlank::Audio::Score
    zap = score.new(tempo: 120, parts: [score::Part.new(swell: 3, volume: 4, notes: [score::Note.new(at: 0, key: :E5, length: 48)])])
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      sfx = sound_effects :sfx, { zap: zap }
      sfx.play :zap
      game_loop { wait_vblank }
    end
    b.finalize_program
    nr12, = registers_after(b.program)

    assert_equal 0x4B, nr12, "the zap starts at 4 and steps up every three 64ths of a second"
  end

  # A drum part that says nothing of a note's fade rings out as the part says — which is what it
  # did before notes could say one, and is still the same bytes.
  def test_a_drum_that_says_nothing_rings_out_as_its_part_says
    _, _, nr42 = registers_after(color_program do
      voice :drums, plays: :noise do |v|
        v.decay :medium
        v.note :C2, :whole
      end
    end)

    assert_equal 0xC3, nr42
  end

  # A PAD HELD UNDER THE MUSIC VOLUME is struck again at the loudest the volume lets it be, with no
  # fade under it, so the voice stops counting it up there.
  def test_a_swelling_pad_held_at_half_is_told_to_hold
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) { voice(:lead) { |v| v.rest :whole }; voice(:pad) { |v| v.volume 0; v.swell :fast; v.note :G4, :whole } }
      play_song :tune
      music_volume 50
      game_loop { wait_vblank }
    end
    b.finalize_program
    _, nr22, = registers_after(b.program, frames: 40)

    assert_equal 0x70, nr22, "the pad held at 7 of 15, counting nothing"
  end
end

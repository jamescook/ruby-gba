# frozen_string_literal: true

require "test_helper"

require "stringio"

# Only the first square voice can slide a note's pitch, and a song's first square part plays on it.
# A slide said by the second square part would never be heard — the note would hold its pitch, with
# nothing to say why — so the build stops, naming the part, and the fix is to put it first.
class TestSlideOffFirstSquareGuardrail < Minitest::Test
  Score = VBlank::Audio::Score

  private def build_errors(&program)
    err = StringIO.new
    assert_raises(VBlank::BuildError) do
      VBlank.build("SLIDES", console: :gba, out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        instance_exec(&program)
        game_loop { wait_vblank }
      end
    end
    err.string
  end

  def test_a_slide_on_the_second_square_part_stops_the_build_naming_it
    said = build_errors do
      song(:tune) do
        voice(:bass) { |v| v.note :C3, :whole }
        voice(:lead) { |v| v.note :C5, :whole, slide_up: :fast }
      end
      play_song :tune
    end

    assert_match(/:lead .* is the second square part/, said)
    assert_match(/before the other square part/, said)
  end

  # A Score names the part by its place, and a sound effect is checked the same as a song.
  def test_a_sound_effects_second_square_part_is_checked_too
    zap = Score.new(parts: [Score::Part.new(notes: [Score::Note.new(at: 0, key: 60)]),
                            Score::Part.new(slide_down: :slow, notes: [Score::Note.new(at: 0, key: 72)])])
    said = build_errors { sound_effects(:sfx, { zap: zap }).play :zap }

    assert_match(/Part 1 of the sound effect :zap/, said)
    assert_match(/is the second square part/, said)
  end

  # `:none` asks for no slide, so any part can say it: the second square part, the drums.
  def test_saying_no_slide_is_not_a_slide
    rom = VBlank.build("SLIDES", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      enable_sound
      song(:tune) do
        voice(:lead) { |v| v.note :C5, :whole }
        voice(:bass) { |v| v.note :C3, :whole, slide_down: :none }
        voice(:drums, plays: :noise) { |v| v.note :C2, :whole, slide_up: :none }
      end
      play_song :tune
      game_loop { wait_vblank }
    end

    refute_nil rom
  end

  def test_the_first_square_part_can_slide_with_another_beside_it
    rom = VBlank.build("SLIDES", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      enable_sound
      song(:tune) do
        voice(:lead) { |v| v.note :C5, :whole, slide_up: :fast }
        voice(:bass) { |v| v.note :C3, :whole }
      end
      play_song :tune
      game_loop { wait_vblank }
    end

    refute_nil rom
  end
end

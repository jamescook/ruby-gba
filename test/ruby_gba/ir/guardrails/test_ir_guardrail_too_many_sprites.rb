# frozen_string_literal: true

require "test_helper"

# More sprites than the console has places for.
#
# The console keeps one table of 128 sprites, and every sprite a game declares takes a place
# in it. That used to be a number an author counted, until tiled text: every character is a
# sprite of its own, so a game can cross the line by rewording a label. The refusal came out
# of the ROM lowering as a bare count, after everything else had passed, and said nothing
# about what the sprites were.
class TestIRGuardrailTooManySprites < Minitest::Test
  Guardrails = RubyGBA::IR::Guardrails

  def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::TooManySprites.new])
  end

  # 100 declared sprites, a pool of 20 and 30 letters of text: 150 in all.
  def game(sprites: 100, letters: 30)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:dot, "#" => :white) { "########\n" * 8 }
      sprites.times { |i| sprite :dot, at: [i % 30 * 8, i / 30 * 8] }
      pool :spark, x: 0, y: 0, capacity: 20, image: :dot
      draw_text "A" * letters, 0, 150, :white
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  def refusal(program) = validator.run(program, autofix: false).errors.first&.message

  def test_more_sprites_than_the_console_has_places_for_is_refused
    message = refusal(game)

    assert_match(/150 sprites/, message, "it says how many the game asks for")
    assert_match(/128/, message, "...and how many the console has")
    assert_match(/30 are letters of text/, message, "...and how many of them are text")
    assert_match(/20 are the places of pool :spark/, message, "...and a pool's share")
    assert_match(/100 are sprites.*:dot/, message, "...and the sprites the game declared, by picture")
    assert_match(/shorter words/, message, "...and what to do about the text")
    assert_match(/smaller `capacity:`/, message, "...and about the pool")
  end

  def test_a_game_that_fits_says_nothing
    assert_nil refusal(game(sprites: 50))
  end

  # The share nobody declared is left out rather than said as nought.
  def test_a_game_with_no_text_says_nothing_about_text
    refute_match(/text/, refusal(game(sprites: 120, letters: 0)))
  end

  # The interpreter is the answer key a game's own tests run against, so it refuses the
  # same programs in the same words rather than drawing 150 sprites the console cannot.
  def test_the_interpreter_refuses_in_the_same_words
    error = assert_raises(Reference::ProgramError) { Reference.new.run(game) }

    assert_equal refusal(game), error.message
  end

  def test_the_lowering_refuses_in_the_same_words
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(game) }

    assert_equal refusal(game), error.message
  end

  def test_build_stops_with_the_explanation
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("SPRITES", out: StringIO.new, err: err) do
        screen :tiled
        image(:dot, "#" => :white) { "########\n" * 8 }
        130.times { |i| sprite :dot, at: [i % 30 * 8, i / 30 * 8] }
        game_loop {}
      end
    end
    assert_match(/130 sprites/, err.string)
  end
end

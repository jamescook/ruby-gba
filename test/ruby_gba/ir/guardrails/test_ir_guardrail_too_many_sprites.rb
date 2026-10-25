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

  private def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::TooManySprites.new])
  end

  # 100 declared sprites, a pool of 20 and 30 letters of text: 150 in all.
  private def game(sprites: 100, letters: 30)
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

  private def refusal(program) = validator.run(program, autofix: false).errors.first&.message

  # A game of three screens the variable :where picks between, each declaring its own
  # sprites, with +shared+ declared outside every scene.
  # +wall+ puts one more sprite every scene shows in a layer between the title's and play's,
  # so it is drawn in front of the title's sprites and behind play's.
  private def scenes(title:, play:, shared: 0, wall: false)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :back, :middle, :front
      image(:dot, "#" => :white) { "########\n" * 8 }
      image(:post, "#" => :red) { "########\n" * 8 }
      shared.times { |i| sprite :dot, at: [i % 30 * 8, 150] }
      layer(:middle) { sprite :post, at: [0, 140] } if wall
      var :where, 0
      scene(:title) { layer(:back) { title.times { |i| sprite :dot, at: [i % 30 * 8, i / 30 * 8] } } }
      scene(:play) { layer(:front) { play.times { |i| sprite :dot, at: [i % 30 * 8, i / 30 * 8] } } }
      scene(:over) {}
      game_loop do
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
          when_val 2, :over
        end
      end
    end
    b.finalize_program
    b.program
  end

  # Two scenes are never up together, so their sprites take turns at the same places: what
  # has to fit is the busiest scene with the sprites every scene shows, not the whole game.
  def test_sprites_of_scenes_never_up_together_share_places
    assert_nil refusal(scenes(title: 100, play: 100, shared: 20))
  end

  def test_the_busiest_scene_over_the_places_is_refused_by_name
    message = refusal(scenes(title: 20, play: 120, shared: 10))

    assert_match(/:play scene has 130 sprites/, message, "it names the busiest scene and counts what it shows")
    assert_match(/128/, message, "...and says how many the console has")
    assert_match(/130 are sprites the game declared/, message, "...and spends the busiest scene's, not the game's")
  end

  # A sprite every scene shows keeps its place on every screen, and the console draws a lower
  # place in front. Drawn in front of the title's sprites and behind play's, it needs the
  # title's places on one side of it and play's on the other.
  def test_a_sprite_drawn_between_two_scenes_sprites_keeps_them_apart
    message = refusal(scenes(title: 70, play: 70, wall: true))

    assert_match(/141 places/, message, "it says how many the game needs")
    assert_match(/Each scene fits/, message, "...that no one scene is the trouble")
    assert_match(/:post keeps the same places in every scene, and it is drawn in front of the sprites of one scene and behind/, message,
                 "...which sprite keeps the scenes apart, and why")
    assert_match(/put :post in a layer behind the sprites of every scene/, message, "...and how to fix it")
    refute_match(/use fewer sprites/, message, "fewer sprites is not the fix")
    assert_nil refusal(scenes(title: 70, play: 70, shared: 1)), "the same sprite drawn behind both lets them share"
  end

  def test_the_lowering_refuses_a_busiest_scene_in_the_same_words
    program = scenes(title: 20, play: 120, shared: 10)
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(program) }

    assert_equal refusal(program), error.message
  end

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
    error = assert_raises(Reference::ProgramError) { game_player.run(game) }

    assert_equal refusal(program_played(game)), error.message
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

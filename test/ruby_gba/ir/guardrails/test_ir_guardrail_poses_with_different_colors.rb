# frozen_string_literal: true

require "test_helper"

# A sprite whose pictures were given different lists of colors.
#
# The console draws every picture of one sprite from one list of sixteen colors, so pictures
# that each came with a list of their own cannot all be shown by one sprite. The cartridge
# build always refused that. The interpreter drew it, each picture in its own colors, so a
# game's own tests were green for a game that could not be built.
class TestIRGuardrailPosesWithDifferentColors < Minitest::Test
  Guardrails = RubyGBA::IR::Guardrails

  WARM = [:transparent, :red, :orange].freeze
  COLD = [:transparent, :blue, :white].freeze
  BOTH = [:transparent, :red, :blue].freeze

  WARM_ART = Array.new(64, :red).freeze
  COLD_ART = Array.new(64, :blue).freeze

  def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::PosesWithDifferentColors.new])
  end

  def program(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      instance_eval(&game)
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  # One sprite that faces two ways, each way a picture with its own list.
  def sprite_game(left: WARM, right: COLD)
    program do
      image :left, width: 8, height: 8, data: WARM_ART, colors: left
      image :right, width: 8, height: 8, data: COLD_ART, colors: right
      sprite :ship, at: [40, 40], facing: { left: :left, right: :right }
    end
  end

  def pool_game
    program do
      image :left, width: 8, height: 8, data: WARM_ART, colors: WARM
      image :right, width: 8, height: 8, data: COLD_ART, colors: COLD
      guards = pool :guard, x: 0, y: 0, capacity: 4, facing: { left: :left, right: :right }
      guards.spawn x: 40, y: 40
    end
  end

  def refusals(program) = validator.run(program, autofix: false).errors.map(&:message)

  def refusal(program) = refusals(program).first

  def test_a_sprite_whose_pictures_have_different_lists_is_refused
    message = refusal(sprite_game)

    assert_match(/sprite :ship/, message, "it names the sprite")
    assert_match(/different `colors:` lists/, message, "...and what is wrong with its pictures")
    assert_match(/:left and :right/, message, "...and which pictures disagree")
    assert_match(/draw_with/, message, "...and the way to recolor one thing that both backends draw")
  end

  # A pool is a sprite a slot, all showing the same pictures, so it is refused one time and
  # by the name the game gave it.
  def test_a_pool_is_refused_one_time_by_its_own_name
    messages = refusals(pool_game)

    assert_equal 1, messages.size
    assert_match(/pool :guard/, messages.first)
  end

  # A picture with a list beside one with none is the same mistake: the framework would have
  # to work a list out for one picture and keep the given list for the other.
  def test_a_picture_with_a_list_beside_one_with_none_is_refused
    message = refusal(sprite_game(right: nil))

    assert_match(/sprite :ship/, message)
    assert_match(/none \(:right\)/, message, "it says which picture has no list, rather than calling it a different one")
  end

  def test_pictures_given_the_same_list_say_nothing
    assert_nil refusal(sprite_game(left: BOTH, right: BOTH))
  end

  def test_pictures_given_no_list_say_nothing
    assert_nil refusal(sprite_game(left: nil, right: nil))
  end

  # The interpreter is the answer key a game's own tests run against, so it refuses the
  # same programs in the same words rather than drawing what the console cannot.
  def test_the_interpreter_refuses_in_the_same_words
    error = assert_raises(Reference::ProgramError) { Reference.new.run(pool_game) }

    assert_equal refusal(pool_game), error.message
  end

  def test_the_lowering_refuses_in_the_same_words
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(pool_game) }

    assert_equal refusal(pool_game), error.message
  end

  # The whole build, on the pool the interpreter refuses above: the game hears of it from the
  # build's own checks, in those words, before any cartridge is made.
  def test_build_stops_with_the_explanation
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("COLORS", out: StringIO.new, err: err) do
        screen :tiled
        image :left, width: 8, height: 8, data: WARM_ART, colors: WARM
        image :right, width: 8, height: 8, data: COLD_ART, colors: COLD
        guards = pool :guard, x: 0, y: 0, capacity: 4, facing: { left: :left, right: :right }
        guards.spawn x: 40, y: 40
        game_loop {}
      end
    end
    assert_includes err.string, refusal(pool_game)
  end
end

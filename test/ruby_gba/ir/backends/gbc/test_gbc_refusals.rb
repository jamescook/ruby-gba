# frozen_string_literal: true

require "test_helper"

# What a Game Boy Color cannot do at all is refused when a cartridge is made for it, in the words
# the Color's answers have (Console::GBCFeatures, through Guardrails::Checks::ColorAnswers) — by
# the lowering itself, so a program handed straight to it, as every test's is, hears the same
# refusal a game's build does rather than playing on without what it asked for.
class TestGBCRefusals < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC

  def test_a_layer_seen_through_by_a_fixed_amount_is_refused_in_plain_words
    error = assert_raises(GBC::LoweringError) { GBC.new.build(ghost_program { 40 }) }

    assert_match(/`transparency:`/, error.message)
    assert_match(/cannot show one layer through another/, error.message)
  end

  def test_a_layer_seen_through_by_an_amount_worked_out_as_it_runs_is_refused_the_same_way
    error = assert_raises(GBC::LoweringError) { GBC.new.build(ghost_program { var(:see, 40) }) }

    assert_match(/cannot show one layer through another/, error.message)
  end

  def test_a_shoulder_button_is_refused_in_plain_words
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        count = var :count, 0
        game_loop { pressed(:l).then { count.add! 1 } }
      end)
    end

    assert_match(/:l button/, error.message)
    assert_match(/no shoulder buttons/, error.message)
  end

  private

  def ghost_program(&amount)
    color_program do
      screen :tiled
      image(:ghost, "#" => :white) { "########\n" * 8 }
      layers :world, :ghosts
      layer(:ghosts, transparency: instance_eval(&amount)) { sprite :ghost, at: [40, 40] }
      game_loop { wait_vblank }
    end
  end

  def color_program(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    program = builder.program
    program.console = :gbc
    program
  end
end

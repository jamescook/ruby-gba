# frozen_string_literal: true

require "test_helper"

# What a Game Boy Color cartridge does with a game's layers (GBC::Picture). A Color has no way to
# mix one layer with another, so a see-through layer is refused in plain words, as the Color's
# answers say (Console::GBCFeatures), however the amount is written.
class TestGBCLayers < Minitest::Test
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

  private

  def ghost_program(&amount)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:ghost, "#" => :white) { "########\n" * 8 }
      layers :world, :ghosts
      layer(:ghosts, transparency: instance_eval(&amount)) { sprite :ghost, at: [40, 40] }
      game_loop { wait_vblank }
    end
    builder.finalize_program
    program = builder.program
    program.console = :gbc
    program
  end
end

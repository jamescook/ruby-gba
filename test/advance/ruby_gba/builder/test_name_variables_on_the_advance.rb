# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_name_variables.rb whose games show a second background while another is
# showing, and a Game Boy Color's hardware cannot, so they play on the Advance's runs alone.
class TestNameVariablesOnTheAdvance < Minitest::Test
  include Differential

  private def program_with(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # --- a name that picks a SCENE ---
  #
  # `call mode` over names that are scenes is the same thing as a `case_var` over them: each
  # scene owns what it declares — its tiled text, its sprites, its scenery — and shows it only
  # while it runs. A title with a banner and a plain backdrop hands over to a walk with none.

  RED = RubyGBA::Graphics::Color.resolve(:red)
  BLUE = RubyGBA::Graphics::Color.resolve(:blue)
  WHITE = RubyGBA::Graphics::Color.resolve(:white)

  private def scenes_by_name
    tile = SOLID_TILE
    program_with do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      image(:spot, "#" => :white) { tile }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      map = Array.new(20) { "#" * 30 }
      background :world, tiles: :red_set, map: map
      mode = var :mode, :title
      b = self
      b.scene :title do
        background :backdrop, tiles: :blue_set, map: map
        draw_text "HI", 8, 8, :white
        sprite :spot, at: [200, 120]
        pressed(:a).then { mode.set! :walk }
      end
      b.scene(:walk) { pressed(:b).then { mode.set! :title } }
      game_loop { b.call mode }
    end
  end

  def test_a_name_can_pick_a_scene_and_the_scene_owns_what_it_declares
    title = game_player.run(scenes_by_name, frames: 3)
    assert_equal BLUE, title.screen.pixel(120, 80), "the title's backdrop is up"
    assert_equal WHITE, title.screen.pixel(204, 124), "and its sprite"
    refute_empty title.sprites.select { |row| row.name.nil? }, "and its text"

    walk = game_player.input_each_frame { |f| f == 2 ? [:a] : [] }.run(scenes_by_name, frames: 6)
    assert_equal RED, walk.screen.pixel(120, 80), "the walk has no backdrop, so the world shows"
    assert_equal RED, walk.screen.pixel(204, 124), "the title's sprite is gone"
    assert_empty walk.sprites.select { |row| row.name.nil? }, "and so is its text"
  end

  def test_both_backends_hand_the_screen_between_scenes_picked_by_name
    assert_backends_agree(scenes_by_name, frames: 3)

    rom = assemble_rom(scenes_by_name, name: "BYNAME")
    v = assert_emulator_loads_rom(rom, frames: 4)
    assert_equal BLUE, v.pixel_gba(120, 80), "the console shows the title's backdrop"
    v.step(2, keys: RubyGBA::Console::Hardware::KEY_A)
    v.step(4)
    assert_equal RED, v.pixel_gba(120, 80), "and the world once the walk has taken over"
    assert_empty v.sprites.select { |row| row.name.nil? }, "the title's text is gone"
  end
end

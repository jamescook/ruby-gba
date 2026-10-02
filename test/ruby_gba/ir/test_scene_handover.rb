# frozen_string_literal: true

require "test_helper"

# WHAT A SCENE DOES TO THE SCREEN AS IT TAKES OVER, asked of the program with no backend
# running. Both backends carry this plan out — the interpreter by painting, the lowering by
# telling the console — so what it says is what both of them do.
class TestSceneHandover < Minitest::Test
  Handover = RubyGBA::IR::SceneHandover
  Stacking = RubyGBA::IR::Stacking

  private def program
    tile = SOLID_TILE
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :back, :front
      image(:art, "#" => :red) { tile }
      tiles :set, "#" => :art
      map = Array.new(20) { "#" * 30 }
      background :sky, tiles: :set, map: map
      scene :menu do
        layer(:front) { background :card, tiles: :set, map: map }
        layer(:back) { background :wall, tiles: :set, map: { plain: map, cracked: map } }
      end
      scene(:walk) { nil }
      state = var :state, 0
      game_loop { case_var(:state) { when_val 0, :menu; when_val 1, :walk } }
    end
    b.finalize_program
    b.program
  end

  private def plan = Handover.of(Stacking.picture(program))

  def test_a_scene_puts_up_its_own_scenery_in_the_order_the_stack_draws_it
    assert_equal %i[wall card], plan.arriving(:_scene_menu).map(&:name)
    assert_empty plan.arriving(:_scene_walk), "a scene with no scenery of its own puts none up"
  end

  def test_what_shows_while_a_scene_runs_is_its_own_scenery_and_what_every_screen_shows
    assert_equal %i[sky wall card], plan.showing(:_scene_menu).map(&:name)
    assert_equal %i[sky], plan.showing(:_scene_walk).map(&:name)
  end

  def test_scenery_a_scene_owns_goes_up_as_it_arrives_and_not_where_it_is_written
    sky, wall, = Stacking.picture(program).scenery
    refute plan.on_arrival?(sky)
    assert plan.on_arrival?(wall)
  end

  def test_the_map_a_scene_shows_goes_back_to_its_first_as_it_arrives
    refute_empty plan.map_choices_to_reset(:_scene_menu), "the wall has two maps, so which one is showing is put back"
    assert_empty plan.map_choices_to_reset(:_scene_walk)
  end

  # Three kinds of screen, and handing over from one kind to another replaces the whole
  # display: a painted picture, one drawn from tiles, and one that turns.
  def test_changing_the_kind_of_screen_replaces_what_was_shown
    assert Handover.crossing?(:bitmap, :tiled)
    assert Handover.crossing?(:bitmap, :rotozoom)
    assert Handover.crossing?(:tiled, :rotozoom)
    refute Handover.crossing?(:tiled, :tiled)
    refute Handover.crossing?(nil, :tiled), "the first screen replaces nothing"
  end
end

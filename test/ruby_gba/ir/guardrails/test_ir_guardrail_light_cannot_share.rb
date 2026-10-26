# frozen_string_literal: true

require "test_helper"

# A spotlight beside something that needs the same part of the display: a see-through
# layer, a fade placed in the stack, a bitmap screen, or no frames to work the light out
# before. Each is refused; a plain fade beside a light is not.
class TestIrGuardrailLightCannotShare < Minitest::Test
  Check = RubyGBA::IR::Guardrails::Checks::LightCannotShare

  # A tiled room with a light, and +said+ run before the loop. +loop+ false leaves the game
  # with no frames.
  private def findings(loop: true, &said)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      layers :ground, :water, :ui
      image(:tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 20 }
      layer(:ui) { sprite :score, at: [8, 8], facing: { right: :tile } }
      spotlight at: [120, 80], radius: 40
      instance_exec(&said) if said
      game_loop { nil } if loop
    end
    builder.finalize_program
    Check.new.detect(builder.program)
  end

  def test_a_light_alone_or_beside_a_plain_fade_is_fine
    assert_empty findings
    assert_empty findings { fade :black, 50 }
  end

  def test_a_light_beside_a_see_through_layer_is_an_error
    found = findings do
      layer(:water, transparency: 40) { background :pond, tiles: :set, map: ["#" * 32] * 20 }
    end

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_predicate found.first, :error?
    assert_match(/:water is see-through/, found.first.message)
  end

  def test_a_light_beside_a_placed_fade_is_an_error
    found = findings { fade :black, 50, under: :ui }

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_match(/remove `under: :ui`/, found.first.message)
  end

  # A game of two scenes, :title and :playing, on a tiled screen: +title+ and +playing+ are each
  # scene's body.
  private def scene_findings(title:, playing:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      layers :ground, :water, :ui
      image(:tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 20 }
      var :mode, 0
      scene(:title) { instance_exec(&title) }
      scene(:playing) { instance_exec(&playing) }
      game_loop { case_var(:mode) { when_val 0, :title; when_val 1, :playing } }
    end
    builder.finalize_program
    Check.new.detect(builder.program)
  end

  private def see_through_water = -> { layer(:water, transparency: 40) { background :pond, tiles: :set, map: ["#" * 32] * 20 } }

  # THE DISPLAY'S MIXING IS SET A FRAME AT A TIME, so a scene that sees through a layer and a
  # scene with the light can take turns with it: the light is off while the first is up.
  def test_a_light_in_one_scene_and_a_see_through_layer_in_another_is_fine
    assert_empty scene_findings(title: see_through_water, playing: -> { iris_out from: 150, by: 4 })
  end

  # The same through a whole build, every check and every step of finishing the program
  # included: the switch the build adds to each scene is not the game moving the light.
  def test_a_whole_build_with_the_light_and_a_see_through_layer_in_different_scenes_builds
    water = see_through_water
    rom = RubyGBA.build("TURNS", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      layers :ground, :water
      image(:tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 20 }
      var :mode, 0
      scene(:title) { instance_exec(&water) }
      scene(:playing) { iris_out from: 150, by: 4 }
      game_loop { case_var(:mode) { when_val 0, :title; when_val 1, :playing } }
    end

    refute_nil rom
  end

  def test_a_light_in_one_scene_and_a_placed_fade_in_another_is_fine
    assert_empty scene_findings(title: -> { fade :black, 50, under: :ui }, playing: -> { iris_out from: 150, by: 4 })
  end

  def test_a_scene_that_sees_through_a_layer_and_uses_the_light_is_an_error
    water = see_through_water
    found = scene_findings(title: -> { instance_exec(&water); iris_out from: 150, by: 4 }, playing: -> {})

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_match(/scene :title/, found.first.message)
    assert_match(/:water is see-through/, found.first.message)
  end

  def test_a_scene_that_fades_under_a_layer_and_uses_the_light_is_an_error
    found = scene_findings(title: -> { fade :black, 50, under: :ui; iris_in by: 4, to: 150 }, playing: -> {})

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_match(/scene :title/, found.first.message)
    assert_match(/remove `under: :ui`/, found.first.message)
  end

  # A fade placed in the stack by the game loop itself, outside every scene, is in force in all of
  # them, the light's scene too.
  def test_a_placed_fade_outside_every_scene_is_an_error
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      layers :ground, :ui
      image(:tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 20 }
      var :mode, 0
      scene(:playing) { iris_out from: 150, by: 4 }
      game_loop do
        fade :black, 50, under: :ui
        case_var(:mode) { when_val 0, :playing }
      end
    end
    builder.finalize_program
    found = Check.new.detect(builder.program)

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_match(/remove `under: :ui`/, found.first.message)
  end

  def test_a_light_in_a_game_that_shows_a_bitmap_screen_is_an_error
    found = findings do
      scene(:title) { screen :bitmap }
      case_var(:mode) { when_val 0, :title }
    end

    assert_match(/screen :bitmap/, found.map(&:message).join)
  end

  def test_a_light_with_no_frames_is_an_error
    found = findings(loop: false)

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_match(/no `game_loop`/, found.first.message)
  end
end

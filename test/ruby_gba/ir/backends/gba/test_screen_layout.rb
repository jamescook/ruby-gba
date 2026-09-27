# frozen_string_literal: true

require "test_helper"

# WHERE EVERYTHING THE CONSOLE DRAWS FOR YOU GOES, asked of the plan itself.
#
# The console holds four background layers and a table of 128 sprites, and which of them
# each thing in a game gets is decided before any code exists. These ask that plan
# directly — which layer a background landed on, how a sprite was cut up — so a slot
# handed out wrong fails here by name instead of as a picture that looks slightly off.
class TestScreenLayout < Minitest::Test
  Layout = RubyGBA::IR::Backends::GBA::ScreenLayout

  private def plan(&game)
    b = Builder.new
    b.instance_eval(&game)
    b.emit_pending_functions
    @program = b.program
    Layout.plan(@program)
  end

  # Where the sprite showing +picture+ landed. A sprite's own name is the framework's, so
  # it is found by the picture the author named.
  private def sprite(layout, picture)
    node = @program.walk.find { |n| n.kind == :object && n.poses.first == picture }
    layout.objects.fetch(node.name)
  end

  # A tiled game with one tileset, :set, of one solid tile, ready for backgrounds.
  private def tiled_game(&rest)
    tile = SOLID_TILE
    plan do
      screen :tiled
      image(:art, "#" => :red) { tile }
      tiles :set, "#" => :art
      instance_exec(Array.new(20) { "#" * 30 }, &rest)
    end
  end

  # --- which of the console's layers a background uses ---

  # The four layers have to cover one screen, never the whole game, so two scenes that
  # take turns can have four backgrounds each.
  def test_scenes_that_take_turns_each_get_all_four_layers
    layout = tiled_game do |map|
      scene(:first) { 4.times { |i| background :"a#{i}", tiles: :set, map: map } }
      scene(:second) { 4.times { |i| background :"b#{i}", tiles: :set, map: map } }
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :first; when_val 1, :second } }
    end

    first = (0...4).map { |i| layout.hardware_layers.fetch(:"a#{i}") }
    second = (0...4).map { |i| layout.hardware_layers.fetch(:"b#{i}") }
    assert_equal [0, 1, 2, 3], first.sort
    assert_equal [0, 1, 2, 3], second.sort, "the second scene reuses the layers the first one had"
  end

  # Scenery every screen shows stays on one layer throughout, because nothing moves it as
  # scenes come and go — so a scene's own backgrounds take the layers left over.
  def test_scenery_every_screen_shows_keeps_its_layer_in_every_scene
    layout = tiled_game do |map|
      background :sky, tiles: :set, map: map
      scene(:first) { background :hall, tiles: :set, map: map }
      scene(:second) { background :cave, tiles: :set, map: map }
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :first; when_val 1, :second } }
    end

    sky = layout.hardware_layers.fetch(:sky)
    refute_equal sky, layout.hardware_layers.fetch(:hall)
    refute_equal sky, layout.hardware_layers.fetch(:cave)
  end

  # --- how a layer's tiles are stored ---

  # A tile drawn from sixteen colours or fewer is stored half a byte a pixel; a layer
  # with even one tile past that stores every tile a byte a pixel.
  def test_a_layer_with_a_tile_of_many_colours_is_stored_the_big_way
    many = (0...64).map { |i| RubyGBA::Graphics::Color.rgb(i % 32, i / 2, 31 - (i % 32)) }
    tile = SOLID_TILE
    layout = plan do
      screen :tiled
      image(:plain, "#" => :red) { tile }
      image :rainbow, width: 8, height: 8, data: many
      tiles :few, "#" => :plain
      tiles :lots, "#" => :rainbow
      map = Array.new(20) { "#" * 30 }
      background :calm, tiles: :few, map: map
      background :loud, tiles: :lots, map: map
      game_loop {}
    end

    assert layout.backgrounds.fetch(:calm).small, "few colours: half a byte a pixel"
    refute layout.backgrounds.fetch(:loud).small, "too many for one group of sixteen: a byte a pixel"
  end

  # --- where the sprites go ---

  # The console's largest picture is 64x64, so a bigger one is several objects standing
  # shoulder to shoulder. One the console can draw whole stays one.
  def test_a_picture_bigger_than_the_console_draws_is_cut_into_pieces
    red = RubyGBA::Graphics::Color.rgb(31, 0, 0)
    layout = plan do
      screen :tiled
      image :boss, width: 96, height: 48, data: [red] * (96 * 48)
      image :coin, width: 16, height: 16, data: [red] * (16 * 16)
      sprite :boss, at: [0, 0]
      sprite :coin, at: [0, 0]
      game_loop {}
    end

    assert_operator sprite(layout, :boss).pieces, :>, 1
    assert_equal 1, sprite(layout, :coin).pieces
  end

  # A lower place in the sprite table draws in front, and the sprite declared last is
  # the one in front — the order every other backend draws them in.
  def test_the_sprite_declared_last_takes_the_front_place
    red = RubyGBA::Graphics::Color.rgb(31, 0, 0)
    layout = plan do
      screen :tiled
      image :back, width: 8, height: 8, data: [red] * 64
      image :front, width: 8, height: 8, data: [red] * 64
      sprite :back, at: [0, 0]
      sprite :front, at: [0, 0]
      game_loop {}
    end

    assert_operator sprite(layout, :front).slot, :<, sprite(layout, :back).slot
  end
end

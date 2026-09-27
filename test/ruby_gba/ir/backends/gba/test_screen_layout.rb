# frozen_string_literal: true

require "test_helper"

# WHERE EVERYTHING THE CONSOLE DRAWS FOR YOU GOES, asked of the plan itself.
#
# The console holds four background layers and a table of 128 sprites, and which of them
# each thing in a game gets is decided before any code exists. These ask that plan
# directly — which layer a background landed on, how a sprite was cut up, where each piece
# of it stands — so a slot handed out wrong fails here by name instead of as a picture that
# looks slightly off.
class TestScreenLayout < Minitest::Test
  RED = Color.rgb(31, 0, 0)
  CLEAR = Color.rgb(1, 1, 1)

  private def plan(&game)
    b = Builder.new
    b.instance_eval(&game)
    b.emit_pending_functions
    @program = b.program
    GBA::ScreenLayout.plan(@program)
  end

  # The object node drawing +picture+. A sprite's own name is the framework's, so it is
  # found by the picture the author named.
  private def object_for(picture) = @program.walk.find { |n| n.kind == :object && n.poses.first == picture }

  # Where the sprite showing +picture+ landed.
  private def sprite(layout, picture) = layout.objects.fetch(object_for(picture).name)

  # ...and where each of its pieces stands, pose by pose.
  private def pieces(layout, picture) = layout.pieces_of(object_for(picture).name)

  # A tiled game with one tileset, :set, of one solid tile, handed a map of that tile
  # +cols+ by +rows+ cells to declare its backgrounds with.
  private def tiled_game(cols: 30, rows: 20, &rest)
    tile = SOLID_TILE
    plan do
      screen :tiled
      image(:art, "#" => :red) { tile }
      tiles :set, "#" => :art
      instance_exec(Array.new(rows) { "#" * cols }, &rest)
    end
  end

  # A +w+ by +h+ picture drawn in red wherever the block says, and see-through elsewhere.
  private def art(w, h)
    (0...(w * h)).map { |i| yield(i % w, i / w) ? RED : CLEAR }
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
    many = (0...64).map { |i| Color.rgb(i % 32, i / 2, 31 - (i % 32)) }
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

  # --- where a background's map goes ---

  # A map that fills no more than one block lands in one, on the smallest of the console's
  # grid sizes, so nothing that worked before bigger maps existed moved.
  def test_a_small_map_uses_one_block
    layout = tiled_game(cols: 32, rows: 32) do |map|
      background :field, tiles: :set, map: map
      game_loop {}
    end
    field = layout.backgrounds.fetch(:field)

    assert_equal GBA::MAP_ENTRIES_A_BLOCK, field.map_units, "one screen block"
    assert_equal 0, field.size, "and the smallest of the console's grid sizes"
  end

  def test_the_biggest_map_takes_four_blocks
    layout = tiled_game(cols: 64, rows: 64) do |map|
      background :field, tiles: :set, map: map
      game_loop {}
    end

    assert_equal 4 * GBA::MAP_ENTRIES_A_BLOCK, layout.backgrounds.fetch(:field).map_units
  end

  # Four maps of the biggest size must not land on each other.
  def test_four_big_maps_get_runs_that_do_not_overlap
    layout = tiled_game(cols: 64, rows: 64) do |map|
      4.times { |i| background :"layer#{i}", tiles: :set, map: map }
      game_loop {}
    end

    spans = layout.backgrounds.values.map { |bg| bg.screen_block...(bg.screen_block + 4) }
    spans.combination(2).each do |a, b|
      assert (a.to_a & b.to_a).empty?, "two maps share screen blocks: #{a} and #{b}"
    end
  end

  # --- where the sprites go ---

  # The console's largest picture is 64x64, so a bigger one is several objects standing
  # shoulder to shoulder. One the console can draw whole stays one.
  def test_a_picture_bigger_than_the_console_draws_is_cut_into_pieces
    layout = plan do
      screen :tiled
      image :boss, width: 96, height: 48, data: [RED] * (96 * 48)
      image :coin, width: 16, height: 16, data: [RED] * (16 * 16)
      sprite :boss, at: [0, 0]
      sprite :coin, at: [0, 0]
      game_loop {}
    end

    assert_operator sprite(layout, :boss).pieces, :>, 1
    assert_equal 1, sprite(layout, :coin).pieces
  end

  # WHERE EACH PIECE STANDS is the thing that can go wrong without looking wrong: a piece
  # one cell out still draws a plausible picture. Between them the pieces have to cover
  # every part of the picture, and each has to start inside it. (A piece may hang past the
  # far edge — the console has no 48-tall size, so a 64-tall one stands there — and what
  # hangs out there draws nothing.)
  def test_the_pieces_of_a_big_sprite_cover_its_picture
    layout = plan do
      screen :tiled
      image :boss, width: 96, height: 48, data: [RED] * (96 * 48)
      sprite :boss, at: [0, 0]
      game_loop {}
    end
    boxes = pieces(layout, :boss).first

    boxes.each do |x, y, w, h, _|
      assert_includes 0...96, x, "a piece starts past the right edge: #{[x, y, w, h]}"
      assert_includes 0...48, y, "a piece starts past the bottom edge: #{[x, y, w, h]}"
    end
    (0...48).step(8).to_a.product((0...96).step(8).to_a).each do |cy, cx|
      covered = boxes.any? { |x, y, w, h, _| cx >= x && cx < x + w && cy >= y && cy < y + h }
      assert covered, "no piece covers the cell at (#{cx}, #{cy})"
    end
  end

  # A piece that would draw nothing is not kept, which is what makes a ragged character
  # cheaper than its canvas: here the right half of the canvas is empty.
  def test_no_piece_stands_where_nothing_is_drawn
    half = art(128, 64) { |x, _y| x < 64 }
    layout = plan do
      screen :tiled
      image :ship, width: 128, height: 64, data: half, transparent: CLEAR
      sprite :ship, at: [0, 0]
      game_loop {}
    end

    pieces(layout, :ship).first.each do |x, y, w, h, _|
      assert_operator x, :<, 64, "a piece stands in the empty half: #{[x, y, w, h]}"
    end
  end

  # --- the table of poses ---

  # Poses cut to different sizes carry their own box each, read out of the table the
  # console is given, so the picture does not move as the sprite changes pose.
  def test_each_pose_carries_its_own_box
    full = art(16, 16) { true }
    corner = art(16, 16) { |x, y| x < 8 && y < 8 }
    layout = plan do
      screen :tiled
      image :full, width: 16, height: 16, data: full, transparent: CLEAR
      image :corner, width: 16, height: 16, data: corner, transparent: CLEAR
      sprite :walker, at: [0, 0], frames: %i[full corner], rate: 4
      game_loop {}
    end

    assert_equal [[[0, 0, 16, 16, false]], [[0, 0, 8, 8, false]]], pieces(layout, :full)
  end

  # A pose that is another one mirrored keeps no pixels of its own: it points at the
  # stored pose, says to draw it backwards, and stands where the reflection falls.
  def test_a_mirrored_pose_stands_where_its_reflection_falls
    corner = art(16, 16) { |x, y| x < 8 && y < 8 }
    layout = plan do
      screen :tiled
      image :corner, width: 16, height: 16, data: corner, transparent: CLEAR
      sprite :walker, at: [0, 0], frames: [:corner, mirror(:corner)], rate: 4
      game_loop {}
    end

    assert_equal [[[0, 0, 8, 8, false]], [[8, 0, 8, 8, true]]], pieces(layout, :corner)
  end

  # A lower place in the sprite table draws in front, and the sprite declared last is
  # the one in front — the order every other backend draws them in.
  def test_the_sprite_declared_last_takes_the_front_place
    layout = plan do
      screen :tiled
      image :back, width: 8, height: 8, data: [RED] * 64
      image :front, width: 8, height: 8, data: [RED] * 64
      sprite :back, at: [0, 0]
      sprite :front, at: [0, 0]
      game_loop {}
    end

    assert_operator sprite(layout, :front).slot, :<, sprite(layout, :back).slot
  end
end

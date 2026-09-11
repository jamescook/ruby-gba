# frozen_string_literal: true

require "test_helper"

# Where tiled backgrounds live in video memory, and why they cannot collide.
#
# A tiled background is two separate things in memory: the tile PICTURES (a
# character block) and the MAP that says which picture goes in which cell (a
# screen block). Both live in the same video memory, one after the other, and the
# hardware is told where each begins. Point them at overlapping addresses and each
# writes over the other — the maps get drawn as if they were pictures and the
# picture data gets read as tile numbers, which looks like confetti rather than
# like an error.
#
# The framework picks both addresses, so a game can never point them anywhere. They
# grow toward each other — tile pictures from the bottom, maps from the top in
# 2K blocks — and the build stops with an explanation when they would meet. What
# that replaced was a fixed rule (tiles capped at the first 16K, maps at fixed
# places just above it) which gave a whole game 256 tiles however few maps it had.
class TestVramLayout < Minitest::Test
  include RubyGBA::IR::Build

  SOLID8 = (["########"] * 8).join("\n")

  # --- The layout itself ---

  # The invariant the whole design rests on: whatever the tiles took and whatever the
  # maps took, together they are inside the memory there is. Held against a program
  # that uses every layer the console has.
  def test_the_tiles_and_the_maps_are_inside_the_memory_there_is
    backend = GBA.new
    backend.lower(four_layer_program)

    tile_end = backend.bg_shared[:char_units] * 2
    first_map = backend.backgrounds.values.map(&:screen_block).min * GBA::SCREENBLOCK_BYTES
    assert_operator tile_end, :<=, first_map, "tile pictures must stop before the first map"
    assert_operator backend.backgrounds.values.map(&:screen_block).max, :<,
                    GBA::TileVram::SCREEN_BLOCKS, "and the last map inside the memory"
  end

  # Every map gets a screen block of its own, and one map is exactly one screen block
  # — so no two layers' maps can land on each other.
  def test_each_layer_gets_its_own_screen_block
    backend = GBA.new
    backend.lower(four_layer_program)
    backgrounds = backend.backgrounds

    blocks = backgrounds.values.map(&:screen_block)
    assert_equal blocks.uniq, blocks, "two layers must never share a screen block"

    backgrounds.each_value do |bg|
      assert_equal GBA::SCREENBLOCK_BYTES, bg.map_units * 2,
                   "a map fills exactly one screen block, so the next one starts clear of it"
    end
  end

  # --- The two limits that keep the layout true ---

  # What limits a tileset now is not the memory but how far a MAP CELL CAN POINT: it
  # holds a tile number in ten bits, counted in that layer's own tile size. So a
  # layer stored two pixels to a byte can name anything in the first 32K — four times
  # what the old fixed cap allowed — and past that the build says so.
  # The headline, as a number rather than as a ratio: a whole game used to get 256
  # distinct tiles across all four layers, and one room of a commercial game uses more
  # than that on its own. A thousand builds now.
  def test_a_thousand_distinct_tiles_build
    names = (0...1000).map { |i| :"t#{i}" }
    prog = program(
      screen(:tiled),
      *names.each_with_index.map { |n, i| striped_tile(n, i) },
      background(:big, tiles: names, map: [[0]], tile_w: 8, tile_h: 8),
      halt,
    )

    backend = GBA.new
    backend.lower(prog)
    assert_equal 1000 * GBA::SMALL_TILE_BYTES, (backend.bg_shared[:char_units] * 2) - GBA::BIG_TILE_BYTES
  end

  # EACH LAYER COUNTS ITS TILE NUMBERS FROM ITS OWN STARTING POINT, which is what makes
  # the ten-bit reach a per-layer limit rather than a whole game's. One layer counting
  # from the bottom names the first 32K; a second told to count from halfway names the
  # rest. So a game can hold more distinct tiles than either layer could name alone —
  # 1600 here, where a single layer stops at about a thousand.
  def test_two_layers_hold_more_tiles_than_one_can_name
    backend = GBA.new
    backend.lower(two_big_tilesets_program(900, 700))

    bases = backend.backgrounds.values.map(&:char_base)
    assert_equal [0], [bases.first], "the first layer still counts from the bottom"
    refute_equal 0, bases.last, "the second one counts from a place of its own"
  end

  def test_too_many_tiles_is_a_friendly_build_error
    over = GBA::TileVram::MOST_TILES + 2
    names = (0...over).map { |i| :"t#{i}" }
    prog = program(
      screen(:tiled),
      # Every tile a different color, so none of them is shared away and the count is
      # really the count. Colors repeat every eight so the color table still fits.
      *names.each_with_index.map { |n, i| striped_tile(n, i) },
      background(:big, tiles: names, map: [[0]], tile_w: 8, tile_h: 8),
      halt,
    )

    error = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/:big/, error.message, "it names the background")
    assert_match(/fewer/i, error.message, "and says what to do about it")
  end

  # Two tiles that come out the same are stored once, whatever tilesets they came
  # from. Nothing about a tileset says which of its tiles are really the same picture,
  # and on a real one that is a large fraction — a wall's interior repeats in every
  # variation of that wall.
  def test_identical_tiles_are_stored_once
    backend = GBA.new
    backend.lower(repeated_tiles_program)

    # The blank tile every empty cell points at (stored the big way so either kind of
    # layer can read it), plus the ONE picture the four tilesets all drew.
    assert_equal GBA::BIG_TILE_BYTES + GBA::SMALL_TILE_BYTES, backend.bg_shared[:char_units] * 2
  end

  def test_tiles_that_differ_are_not_shared
    backend = GBA.new
    backend.lower(four_layer_program)

    # The blank tile (stored the big way so either kind of layer can read it) and the
    # four landmark tiles, each a different color.
    assert_equal GBA::BIG_TILE_BYTES + (4 * GBA::SMALL_TILE_BYTES),
                 backend.bg_shared[:char_units] * 2
  end

  # Every tiled layer draws from one table of colors, so a game whose tiles name
  # more of them between them than the table holds has to be told, not left to fail
  # while packing a number into a pixel.
  def test_too_many_colors_is_a_friendly_build_error
    over = GBA::PaletteBanks::CAPACITY + 1
    names = (0...over).map { |i| :"c#{i}" }
    prog = program(
      screen(:tiled),
      # Each tile takes sixteen colors nothing else uses, so the banks run out first
      # and every one of these ends up drawing from the whole table.
      *names.each_with_index.map { |n, i| many_color_tile(n, i) },
      background(:many, tiles: names, map: [[0]], tile_w: 8, tile_h: 8),
      halt,
    )

    error = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/#{GBA::PaletteBanks::CAPACITY}/, error.message, "it names the limit")
    assert_match(/color/i, error.message)
    assert_match(/fewer/i, error.message, "and says what to do about it")
  end

  # Past four layers there are no more background layers to give, and the map area
  # would grow past what the layout reserves.
  def test_too_many_layers_is_a_friendly_build_error
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:t, "#" => :red) { SOLID8 }
      tiles :set, "R" => :t
      (GBA::MAX_BG_LAYERS + 1).times { |i| background :"layer#{i}", tiles: :set, map: ["R"] }
      game_loop {}
    end
    builder.emit_pending_functions

    error = assert_raises(GBA::LoweringError) { GBA.new.lower(builder.program) }
    assert_match(/#{GBA::MAX_BG_LAYERS}/, error.message, "it names the limit")
    assert_match(/background/i, error.message)
  end

  # --- The proof on hardware ---

  # The worst case the layout has to survive: every layer the console has, stacked
  # at once. If the maps and the tile pictures shared any memory, each layer's
  # landmark would come out as garbage instead of its own flat color. Four distinct
  # colors at four known spots is what "they did not collide" looks like.
  LANDMARKS = [[:red, 5], [:green, 10], [:blue, 15], [:yellow, 20]].freeze

  def test_all_four_layers_render_without_corrupting_each_other
    rom = ROM.assemble(GBA.new.lower(four_layer_program),
                       title: "LAYOUT", code: "BLYT", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)

    LANDMARKS.each_with_index do |(color, cell), layer|
      x = (cell * 8) + 4
      assert v.pixel_is?(x, 4, color),
             "layer #{layer}'s landmark should be #{color} at x=#{x}, " \
             "got 0x#{format('%04X', v.pixel_gba(x, 4))}"
    end
  end

  # A LAYER COUNTING FROM SOMEWHERE ELSE STILL DRAWS ITS OWN TILES, on the console.
  # This is the one that can catch every way the feature goes wrong at once: the first
  # layer fills the whole run its map can reach, so the second is given a starting point
  # of its own. If that starting point never reached the hardware, the second layer's
  # numbers would land a long way back in the first layer's tiles and it would show
  # filler. If its blank tile were wrong, its empty cells would show filler too, over the
  # whole screen. Two flat colors where they belong, and backdrop everywhere else.
  def test_a_layer_with_its_own_starting_point_renders
    rom = ROM.assemble(GBA.new.lower(stacked_tilesets_program),
                       title: "CHARBASE", code: "BCHB", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)

    assert v.pixel_is?((5 * 8) + 4, 4, :red),
           "the first layer's landmark, got 0x#{format('%04X', v.pixel_gba((5 * 8) + 4, 4))}"
    assert v.pixel_is?((10 * 8) + 4, 4, :green),
           "the second layer's landmark, got 0x#{format('%04X', v.pixel_gba((10 * 8) + 4, 4))}"
    assert v.black?(120, 80),
           "and an empty cell of the moved layer shows through, got " \
           "0x#{format('%04X', v.pixel_gba(120, 80))}"
  end

  private

  # Two layers whose tilesets together hold more distinct tiles than one layer's map can
  # name. Every tile is a different picture, so none of them is shared away.
  def two_big_tilesets_program(first, second)
    a = (0...first).map { |i| :"a#{i}" }
    b = (0...second).map { |i| :"b#{i}" }
    program(
      screen(:tiled),
      *a.each_with_index.map { |n, i| striped_tile(n, i) },
      *b.each_with_index.map { |n, i| striped_tile(n, first + i) },
      background(:back, tiles: a, map: [[0]], tile_w: 8, tile_h: 8),
      background(:front, tiles: b, map: [[0]], tile_w: 8, tile_h: 8),
      halt,
    )
  end

  # The same shape, sized so the second layer really is pushed off the bottom, and with
  # one flat landmark in each so the console can be asked what it drew. The first layer's
  # filler fills its reach; the second's is only there to make it too big to squeeze in
  # behind, which is what forces it a starting point of its own.
  def stacked_tilesets_program
    filler = (0...1000).map { |i| :"f#{i}" }
    spare = (0...30).map { |i| :"s#{i}" }
    program(
      screen(:tiled),
      *filler.each_with_index.map { |n, i| striped_tile(n, i) },
      *spare.each_with_index.map { |n, i| striped_tile(n, 1000 + i) },
      tile_bitmap(:mark_a, Color.resolve(:red)),
      tile_bitmap(:mark_b, Color.resolve(:green)),
      background(:back, tiles: filler + [:mark_a], map: [[nil] * 5 + [1000]],
                        tile_w: 8, tile_h: 8),
      background(:front, tiles: [:mark_b] + spare, map: [[nil] * 10 + [0]],
                         tile_w: 8, tile_h: 8),
      halt,
    )
  end


  # A flat 8x8 tile picture in one 15-bit color.
  def tile_bitmap(name, color)
    bitmap(name, width: 8, height: 8, pixels: [color].pack("v") * 64, transparent: nil)
  end

  # A tile drawn from sixteen colors nobody else uses — one past what a bank holds,
  # so it can only be stored the big way and its colors come out of the whole table.
  def many_color_tile(name, run)
    colors = (0...16).map { |i| 0x0001 + (run * 16) + i }
    bitmap(name, width: 8, height: 8, pixels: (colors * 4).pack("v*"), transparent: nil)
  end

  # A tile no other tile matches, drawn from a handful of colors that repeat across
  # the set — so a program of thousands of these fills the tile area without also
  # filling the color table. The run number is spelled out in the first four pixels,
  # eight colors to a digit, which is four thousand distinct tiles out of eight colors.
  def striped_tile(name, run)
    pixels = Array.new(64, 0x0001)
    4.times { |digit| pixels[digit] = 0x0001 + ((run >> (digit * 3)) & 7) }
    bitmap(name, width: 8, height: 8, pixels: pixels.pack("v*"), transparent: nil)
  end

  # Four tilesets that all draw the same picture. Nothing in the program says they
  # are the same; the build notices.
  def repeated_tiles_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:brick, "#" => :red) { SOLID8 }
      4.times do |layer|
        tiles :"set#{layer}", "#" => :brick
        background :"layer#{layer}", tiles: :"set#{layer}", map: [(" " * layer) + "#"]
      end
      game_loop {}
    end
    builder.emit_pending_functions
    builder.program
  end

  # All four layers at once. Each puts one solid landmark tile in its own column of
  # the top row and leaves every other cell empty, so all four show side by side and
  # each one's color says whose tile data was read.
  def four_layer_program
    builder = Builder.new
    marks = LANDMARKS
    builder.instance_eval do
      screen :tiled
      marks.each_with_index do |(color, cell), layer|
        image(:"tile#{layer}", "#" => color) { SOLID8 }
        tiles :"set#{layer}", "#" => :"tile#{layer}"
        row = (" " * cell) + "#"
        background :"layer#{layer}", tiles: :"set#{layer}", map: [row]
      end
      game_loop {}
    end
    builder.emit_pending_functions
    builder.program
  end
end

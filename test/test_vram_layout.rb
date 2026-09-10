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
# The framework picks both addresses, so a game can never point them anywhere. The
# layout leaves no room for an overlap: tile pictures start at the bottom of video
# memory and are capped at one character block, and the first map starts at the
# byte immediately after that block. Two build-time limits hold that shape, and
# both are friendly errors rather than a corrupt picture.
class TestVramLayout < Minitest::Test
  include RubyGBA::IR::Build

  SOLID8 = (["########"] * 8).join("\n")

  # --- The layout itself ---

  # The invariant the whole design rests on: the most tile data a program can have
  # ends exactly where the first map begins. One byte more and they would overlap,
  # which is what the tile cap below exists to stop.
  def test_the_tile_area_ends_exactly_where_the_first_map_begins
    tile_bytes = GBA::TILE_PX * GBA::TILE_PX # 256-color tiles: one byte per pixel
    tile_area_end = GBA::CHAR_BLOCK_TILES * tile_bytes
    first_map_start = GBA::FIRST_MAP_SCREENBLOCK * GBA::SCREENBLOCK_BYTES

    assert_equal first_map_start, tile_area_end,
                 "tile pictures must end where the first map starts — a gap wastes memory, " \
                 "an overlap corrupts both"
  end

  # Every map gets a screen block of its own, in declaration order, and one map is
  # exactly one screen block — so no two layers' maps can land on each other.
  def test_each_layer_gets_its_own_screen_block
    backend = GBA.new
    backend.lower(four_layer_program)
    backgrounds = backend.backgrounds

    blocks = backgrounds.values.map(&:screen_block)
    assert_equal blocks.uniq, blocks, "two layers must never share a screen block"
    assert_equal GBA::FIRST_MAP_SCREENBLOCK, blocks.min, "maps start just past the tile pictures"

    backgrounds.each_value do |bg|
      assert_equal GBA::SCREENBLOCK_BYTES, bg.map_units * 2,
                   "a map fills exactly one screen block, so the next one starts clear of it"
    end
  end

  # --- The two limits that keep the layout true ---

  # Past one character block the tile pictures would run into the first map. The
  # build stops with an explanation instead.
  #
  # HOW MANY TILES that is depends on how each one is stored: a tile drawn from
  # fifteen colors or fewer is packed two pixels to a byte, so twice as many fit.
  # These are, so it takes twice the old cap plus one to run out.
  def test_too_many_tiles_is_a_friendly_build_error
    over = (GBA::CHAR_BLOCK_BYTES / GBA::SMALL_TILE_BYTES) + 1
    names = (0...over).map { |i| :"t#{i}" }
    prog = program(
      screen(:tiled),
      # Colors repeat, so this trips the tile limit and not the color limit.
      *names.each_with_index.map { |n, i| tile_bitmap(n, 0x0001 + (i % 8)) },
      background(:big, tiles: names, map: [[0]], tile_w: 8, tile_h: 8),
      halt,
    )

    error = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/#{GBA::CHAR_BLOCK_BYTES}/, error.message, "it names the room there is")
    assert_match(/:big/, error.message, "and names the background that used it")
    assert_match(/fewer/i, error.message, "and says what to do about it")
  end

  # Storing tiles two pixels to a byte is what doubles this, and it is worth pinning
  # as a number rather than as a ratio: a tileset that fits today is a tileset that
  # would not have fitted before.
  def test_twice_as_many_small_tiles_fit_as_big_ones
    assert_equal 2 * GBA::CHAR_BLOCK_TILES, GBA::CHAR_BLOCK_BYTES / GBA::SMALL_TILE_BYTES
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
    v = assert_gemba_loads_rom(rom, frames: 4)

    LANDMARKS.each_with_index do |(color, cell), layer|
      x = (cell * 8) + 4
      assert v.pixel_is?(x, 4, color),
             "layer #{layer}'s landmark should be #{color} at x=#{x}, " \
             "got 0x#{format('%04X', v.pixel_gba(x, 4))}"
    end
  end

  private

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

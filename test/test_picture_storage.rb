# frozen_string_literal: true

require "test_helper"
require "differential"

# HOW A PICTURE IS STORED, which nobody writes and everybody pays for.
#
# The console reads a picture's pixels one of two ways: a whole byte each, naming any of 256
# colours, or half a byte each, naming 16. Half a byte is half the video memory for the same
# picture drawn at the same speed — and the 16 are not the same 16 for every picture, because
# the colour table is read in banks of sixteen and a picture says which bank it draws from.
#
# So the framework counts the colours in each piece of art and decides. Nothing in the DSL says
# which a picture got, and these tests are about what that is worth and about the one thing that
# must never change: the pixels on screen.
class TestPictureStorage < Minitest::Test
  include Differential

  # Sixteen colours is one too many for a bank (the sixteenth slot means see-through), so a
  # picture drawn from these is stored the big way and one drawn from any fifteen is not.
  SIXTEEN = (1..16).map { |i| RubyGBA::Color.rgb(i, 0, 0) }.freeze
  FIFTEEN = SIXTEEN.first(15).freeze

  # A 16x16 picture painted in stripes of the given colours, so every one of them is really
  # drawn and none can be optimised away.
  def striped(colors)
    (0...256).map { |i| colors[i % colors.length] }
  end

  def build(title, &block)
    RubyGBA.build(title, code: "B#{title[0, 3]}", maker: "01",
                         out: StringIO.new, err: StringIO.new, &block)
  end

  # --- what it saves ---

  def test_a_sprite_drawn_from_few_colors_takes_half_the_sprite_memory
    art = striped(FIFTEEN)
    rom = build("SMALL") do
      screen :tiled
      image :ship, width: 16, height: 16, data: art
      sprite :ship, at: [20, 20]
      game_loop {}
    end

    sprites = rom.built.video_memory.sprites
    assert_equal 1, sprites.small, "the framework chose the small storage without being asked"
    assert_equal 0, sprites.big
    assert_equal 128, sprites.used, "16x16 pixels at half a byte each"
    assert_equal 128, sprites.saved, "which is 128 bytes it would have spent otherwise"
  end

  def test_a_sprite_with_more_colors_than_a_bank_holds_keeps_the_big_storage
    art = striped(SIXTEEN)
    rom = build("BIG") do
      screen :tiled
      image :ship, width: 16, height: 16, data: art
      sprite :ship, at: [20, 20]
      game_loop {}
    end

    sprites = rom.built.video_memory.sprites
    assert_equal 0, sprites.small, "sixteen colours is one past what a bank holds"
    assert_equal 1, sprites.big
    assert_equal 256, sprites.used, "16x16 pixels at a whole byte each"
    assert_equal 0, sprites.saved
  end

  # The tile budget is the one this doubles, and it is the one a real tileset runs into.
  def test_twice_as_many_tiles_fit_when_they_are_stored_small
    small = tile_budget(FIFTEEN)
    big = tile_budget(SIXTEEN)
    assert_equal 2 * big, small, "a tileset drawn from few colours gets twice the room"
  end

  # How many tiles of this kind the character block would hold, worked out from what one costs.
  def tile_budget(colors)
    art = striped(colors).first(64)
    rom = build("TILE#{colors.length}") do
      screen :tiled
      image :brick, width: 8, height: 8, data: art
      tiles :walls, "#" => :brick
      background :room, tiles: :walls, map: ["#"]
      game_loop {}
    end
    tiles = rom.built.video_memory.tiles
    # `used` also holds the blank tile every map's empty cells point at, which is always
    # stored the big way so either kind of layer can read it.
    RubyGBA::IR::Backends::GBA::CHAR_BLOCK_BYTES / (tiles.used - 64)
  end

  # --- the thing that must not change: the pixels ---

  # The acceptance that matters. Two pictures with sixteen colours each, sharing none, drawn
  # side by side — which is exactly what one shared table could never do and is the whole
  # reason banks are worth having.
  def two_palettes_program
    reds = (1..15).map { |i| RubyGBA::Color.rgb(i * 2, 0, 0) }
    blues = (1..15).map { |i| RubyGBA::Color.rgb(0, 0, i * 2) }
    left = striped(reds)
    right = striped(blues)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :floor, "#" => :green do
        (["########"] * 8).join("\n")
      end
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      image :red_ship, width: 16, height: 16, data: left
      image :blue_ship, width: 16, height: 16, data: right
      sprite :red_ship, at: [40, 40]
      sprite :blue_ship, at: [80, 40]
      game_loop {}
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_two_sprites_with_their_own_sixteen_colors_draw_at_once
    assert_backends_agree(two_palettes_program, frames: 2)
  end

  # A picture past a bank and a picture inside one, in the same game. The two storages share
  # one table and one block of sprite memory, so this is where an alignment mistake shows.
  def mixed_program
    small = striped(FIFTEEN)
    big = striped(SIXTEEN)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :floor, "#" => :blue do
        (["########"] * 8).join("\n")
      end
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      image :few, width: 16, height: 16, data: small
      image :many, width: 16, height: 16, data: big
      sprite :few, at: [40, 40]
      sprite :many, at: [80, 40]
      game_loop {}
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_small_and_a_big_sprite_draw_side_by_side
    assert_backends_agree(mixed_program, frames: 2)
  end

  # A tileset drawn from more colours than a bank holds keeps the big storage, and the blank
  # tile an empty cell points at has to stay readable to it. This is a whole screen of both.
  def big_tileset_program
    bricks = striped(SIXTEEN).first(64)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :brick, width: 8, height: 8, data: bricks
      image :grass, "#" => :green do
        (["########"] * 8).join("\n")
      end
      tiles :walls, "#" => :brick, "." => :grass
      background :room, tiles: :walls, map: Array.new(20) { |r| (r.even? ? "#." : ".#") * 15 }
      game_loop {}
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_big_tileset_draws_the_same_on_both_backends
    assert_backends_agree(big_tileset_program, frames: 2)
  end

  # --- art that came with its own table ---

  # `colors:` says the picture's own list, in its own order, see-through first. What it must
  # do is keep the order; what it must not do is change a pixel.
  def test_a_picture_given_its_own_colors_draws_the_same_as_one_without
    listed = [:transparent, *FIFTEEN]
    art = striped(FIFTEEN)
    with = build("WITH") do
      screen :tiled
      image :ship, width: 16, height: 16, data: art, colors: listed
      sprite :ship, at: [20, 20]
      game_loop {}
    end
    without = build("WOUT") do
      screen :tiled
      image :ship, width: 16, height: 16, data: art
      sprite :ship, at: [20, 20]
      game_loop {}
    end

    assert_equal 1, with.built.video_memory.sprites.small, "it is still stored the small way"
    assert_equal without.built.video_memory.sprites.used, with.built.video_memory.sprites.used
  end

  # The order a picture's own list is kept in is what art from somewhere else is drawn
  # against, so it is worth pinning directly. A picture that says nothing gets the order it
  # happens to use its colours in; one that says gets exactly what it said.
  def test_an_authored_list_becomes_the_bank_as_written
    listed = [0x0000, *FIFTEEN.reverse]
    banks = RubyGBA::IR::Backends::GBA::PaletteBanks.new(
      [RubyGBA::IR::Backends::GBA::PaletteBanks::Picture.new(
        key: :ship, colors: FIFTEEN, authored: listed
      )]
    )

    place = banks.placement(:ship)
    assert place.narrow?, "a picture with its own sixteen is stored the small way"
    assert_equal listed, banks.entries[place.bank * 16, 16], "the list is the bank, as written"
    assert_equal 15, place.indices.fetch(FIFTEEN.first), "and a colour's number is where they put it"
  end

  def test_a_picture_without_a_list_reserves_the_see_through_slot
    banks = RubyGBA::IR::Backends::GBA::PaletteBanks.new(
      [RubyGBA::IR::Backends::GBA::PaletteBanks::Picture.new(
        key: :ship, colors: FIFTEEN, authored: nil
      )]
    )

    place = banks.placement(:ship)
    assert_equal 1, place.indices.fetch(FIFTEEN.first), "slot 0 is the see-through one"
    assert_equal 0x0000, banks.entries[place.bank * 16]
  end

  # Two pictures sharing no colours cannot share a bank, and both have to get one.
  def test_pictures_with_different_colors_get_banks_of_their_own
    reds = (1..15).map { |i| RubyGBA::Color.rgb(i, 0, 0) }
    blues = (1..15).map { |i| RubyGBA::Color.rgb(0, 0, i) }
    banks = RubyGBA::IR::Backends::GBA::PaletteBanks.new(
      [RubyGBA::IR::Backends::GBA::PaletteBanks::Picture.new(key: :a, colors: reds, authored: nil),
       RubyGBA::IR::Backends::GBA::PaletteBanks::Picture.new(key: :b, colors: blues, authored: nil)]
    )

    refute_equal banks.placement(:a).bank, banks.placement(:b).bank
    assert_equal 2, banks.narrow_count
  end

  # ...and two that use the same colours share one, which costs nothing and is the common
  # case (every frame of one walk cycle, every tile of one wall).
  def test_pictures_with_the_same_colors_share_a_bank
    banks = RubyGBA::IR::Backends::GBA::PaletteBanks.new(
      [RubyGBA::IR::Backends::GBA::PaletteBanks::Picture.new(key: :a, colors: FIFTEEN, authored: nil),
       RubyGBA::IR::Backends::GBA::PaletteBanks::Picture.new(key: :b, colors: FIFTEEN.first(4), authored: nil)]
    )

    assert_equal banks.placement(:a).bank, banks.placement(:b).bank
  end

  # Past sixteen banks there is nowhere left to put one, and a picture that misses falls back
  # to the big storage rather than the build failing.
  def test_a_picture_that_cannot_get_a_bank_falls_back_to_the_big_storage
    # Eight colours each, none shared, so no two can fit one bank together.
    pictures = (0...20).map do |i|
      colors = (1..8).map { |c| RubyGBA::Color.rgb(c, i + 1, 0) }
      RubyGBA::IR::Backends::GBA::PaletteBanks::Picture.new(key: :"p#{i}", colors: colors, authored: nil)
    end
    banks = RubyGBA::IR::Backends::GBA::PaletteBanks.new(pictures)

    assert_equal 20, banks.narrow_count + banks.wide_count, "every picture is placed somewhere"
    assert_operator banks.wide_count, :>, 0, "the ones that missed a bank read the whole table"
    assert_operator banks.entries.length, :<=, 256
  end

  # --- friendly errors ---

  def test_a_list_longer_than_a_bank_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build("LONG") do
        screen :tiled
        image :ship, width: 4, height: 4, data: Array.new(16, :red), colors: [:transparent, *SIXTEEN]
      end
    end
    assert_match(/:ship/, error.message, "it names the picture")
    assert_match(/17/, error.message, "and how many colours it was given")
    assert_match(/16/, error.message, "and how many it can have")
  end

  def test_drawing_with_a_color_the_list_does_not_hold_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build("MISS") do
        screen :tiled
        image :ship, width: 4, height: 4, data: Array.new(16, :red), colors: [:transparent, :blue]
      end
    end
    assert_match(/:ship/, error.message)
    assert_match(/:red/, error.message, "it names the colour that is missing")
  end

  # The first entry of a picture's own list is the see-through one, whatever colour sits there.
  # A pixel drawn in it would simply not appear, which is worth catching at the line that wrote
  # it rather than leaving as a hole in the art.
  def test_drawing_on_the_see_through_slot_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build("SLOT") do
        screen :tiled
        image :ship, width: 4, height: 4, data: Array.new(16, :red), colors: [:red, :blue]
      end
    end
    assert_match(/:ship/, error.message)
    assert_match(/see-through/i, error.message, "it says what the first entry means")
  end

  def test_poses_given_different_lists_is_a_friendly_error
    art = striped(FIFTEEN)
    other = striped(FIFTEEN.reverse)
    error = assert_raises(GBA::LoweringError) do
      build("POSES") do
        screen :tiled
        image :left, width: 16, height: 16, data: art, colors: [:transparent, *FIFTEEN]
        image :right, width: 16, height: 16, data: other, colors: [:transparent, *FIFTEEN.reverse]
        sprite :hero, at: [0, 0], facing: { left: :left, right: :right }
        game_loop {}
      end
    end
    assert_match(/:left/, error.message, "it names the pictures that disagree")
    assert_match(/:right/, error.message)
    assert_match(/colors:/, error.message)
  end
end

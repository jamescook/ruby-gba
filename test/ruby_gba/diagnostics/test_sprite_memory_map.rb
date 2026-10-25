# frozen_string_literal: true

require "test_helper"

# WHERE EACH SPRITE'S PICTURES WENT IN SPRITE MEMORY, scene by scene. The console keeps the
# pictures it draws sprites from in 32K of their own, and a game that runs out is told only the
# three biggest pictures of the fullest scene. This is the whole of it: every sprite of every
# scene, the tiles it was given, the pictures held there, whether it keeps all its pictures or one
# frame at a time, and which sprites share the same tiles — readable from Ruby, printable, and
# there on the error too, when the build stops because a scene does not fit.
#
# The interpreter has no sprite memory: it draws a sprite from its picture wherever that is. So
# this is the GBA lowering's report alone, and it lives with the reports read off a cartridge.
class TestSpriteMemoryMap < Minitest::Test
  INKS = (1..15).map { |i| Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze
  PICTURES = (0...40).map { |n| :"art_#{n}" }.freeze

  # A 64x64 picture filling its square and differing from every other: 2048 bytes, 64 tiles of
  # sprite memory, stored the small way (fifteen colours).
  def self.art(number)
    (0...64).flat_map do |y|
      (0...64).map do |x|
        next INKS[(number >> (x % 8)) & 1] if y.zero?

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  TILES = 64 # one picture's tiles
  OBJ_START = 0x06010000 # where sprite memory starts on a screen drawn from tiles

  # A badge up in every scene. A play scene: a pool of three showing four pictures, and a boat
  # and a buoy showing the same picture. A menu scene: twelve statues and a hero walking through
  # eight pictures — 2K + 24K + 16K, too much, so the hero keeps one frame at a time.
  private def harbor
    art = TestSpriteMemoryMap.method(:art)
    RubyGBA.build("HARBOR", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      PICTURES.each_with_index { |name, n| image name, width: 64, height: 64, data: art.call(n) }
      sprite :badge, facing: { still: :art_0 }, at: [0, 0]
      var :state, 0
      scene(:playing) do
        pool :gull, x: 0, y: 0, capacity: 3, frames: PICTURES[1..4], rate: 2
        sprite :boat, facing: { still: :art_5 }, at: [40, 40]
        sprite :buoy, facing: { still: :art_5 }, at: [120, 40]
      end
      scene(:menu) do
        PICTURES[6..17].each_with_index { |name, n| sprite :"statue_#{n}", facing: { still: name }, at: [n * 8, 40] }
        sprite :hero, frames: PICTURES[18..25], rate: 2, at: [100, 100]
      end
      game_loop { case_var(:state) { when_val 0, :playing; when_val 1, :menu } }
    end
  end

  private def screens(memory) = memory.screens.to_h { |screen| [screen.scene, screen] }
  private def placed(screen, sprite) = screen.sprites.find { |entry| entry.sprite == sprite }

  def test_every_scene_lists_its_sprites_and_the_ones_up_in_every_scene
    playing, menu = screens(harbor.sprite_memory).values_at(:playing, :menu)

    assert_equal %i[badge boat buoy], playing.sprites.map(&:sprite) & %i[badge boat buoy]
    assert(playing.sprites.any? { |entry| entry.pictures == PICTURES[1..4] }, "the gulls, by the pictures they show")
    assert_includes menu.sprites.map(&:sprite), :badge, "what every scene shows is in every scene's list"
    assert_includes menu.sprites.map(&:sprite), :statue_11
  end

  # Each scene's tiles add up to the number the build checks against the console's 32K. The play
  # scene is the badge, the gulls' four pictures and the boat's one, which the buoy shares: six
  # pictures of 64 tiles. The menu is the badge, twelve statues and a frame of the hero: fourteen.
  def test_a_scenes_runs_add_up_to_what_it_uses
    playing, menu = screens(harbor.sprite_memory).values_at(:playing, :menu)

    [[playing, 6], [menu, 14]].each do |screen, pictures|
      assert_equal pictures * TILES * 32, screen.used, "scene #{screen.scene}"
      runs = screen.sprites.map { |entry| [entry.first_tile, entry.tiles] }.uniq
      assert_equal screen.used, runs.sum { |_, tiles| tiles * 32 }, "its runs, each once"
      assert_equal 0, screen.gaps, "pictures stored the small way leave no gaps"
    end
  end

  # What sharing saved: two of the three gulls show pictures the first holds (four apiece), and
  # the buoy shows the boat's.
  def test_sprites_showing_the_same_picture_share_its_tiles
    playing = screens(harbor.sprite_memory).fetch(:playing)
    boat = placed(playing, :boat)
    buoy = placed(playing, :buoy)

    assert_equal [boat.first_tile, boat.tiles], [buoy.first_tile, buoy.tiles]
    assert_equal TILES, boat.tiles
    assert_equal [:art_5], boat.pictures
    assert_equal [[:art_5, [boat.first_tile]]], boat.poses, "one picture, in one piece, where the run starts"
    assert_includes buoy.shares_with, :boat
    assert_equal ((2 * 4) + 1) * TILES * 32, playing.saved_by_sharing
  end

  # Sprites taking turns at rooms each take a room: nothing is saved, though they draw from one run.
  def test_sprites_taking_turns_at_shared_rooms_save_nothing
    art = TestSpriteMemoryMap.method(:art)
    poses = PICTURES.first(20)
    rom = RubyGBA.build("ROOMS", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      poses.each_with_index { |name, n| image name, width: 64, height: 64, data: art.call(n) }
      shards = pool :shard, x: 0, y: 0, look: 0, capacity: 3, facing: poses.to_h { |name| [name, name] }
      game_loop { shards.each { |shard| shard.face poses, showing: shard.look } }
    end
    screen = rom.sprite_memory.screens.first
    shards = placed(screen, :shard)

    assert_equal :shared_rooms, shards.held
    assert_equal [3, 3 * TILES, TILES], [shards.count, shards.tiles, shards.tiles_alone]
    assert_equal 0, screen.saved_by_sharing
  end

  # The badge is up in every scene and sits first; a scene's own pictures start after it, and those
  # are the tiles written again as the scene takes over.
  def test_a_scene_says_where_its_own_tiles_start
    menu = screens(harbor.sprite_memory).fetch(:menu)

    assert_equal TILES, menu.own_from
    assert_equal 0, placed(menu, :badge).first_tile
    assert_operator placed(menu, :statue_0).first_tile, :>=, menu.own_from
  end

  def test_a_sprite_kept_to_one_frame_says_so_and_is_rewritten_as_it_runs
    menu = screens(harbor.sprite_memory).fetch(:menu)
    hero = placed(menu, :hero)
    statue = placed(menu, :statue_0)

    assert_equal :one_frame, hero.held
    assert_equal TILES, hero.tiles, "room for one frame"
    assert hero.rewritten?
    assert_equal :whole, statue.held
    refute statue.rewritten?
  end

  # A tile number can be laid against a reading of the running console's memory.
  def test_each_range_says_where_it_is_in_the_consoles_memory
    memory = harbor.sprite_memory
    badge = placed(screens(memory).fetch(:playing), :badge)

    assert_equal OBJ_START, memory.start
    assert_equal OBJ_START + (badge.first_tile * 32), badge.address
  end

  def test_the_map_prints
    map = harbor.sprite_memory.to_s

    assert_match(/scene :playing/, map)
    assert_match(/scene :menu/, map)
    assert_match(/all +boat: art_5 \(shared with buoy\)/, map)
    assert_match(/one frame +hero: art_18/, map)
    assert_match(/gull \(3 of them\)/, map, "a pool is one line")
  end

  # Too many still pictures in one scene: nothing to keep to one frame, and the build stops. The
  # error carries the same map, and the fullest scene's total is the number the message gives.
  def test_a_build_that_stops_on_sprite_memory_carries_the_map
    art = TestSpriteMemoryMap.method(:art)
    error = assert_raises(GBA::SpriteMemoryFull) do
      RubyGBA.build("CROWDED", out: StringIO.new, err: StringIO.new) do
        screen :tiled
        PICTURES.each_with_index { |name, n| image name, width: 64, height: 64, data: art.call(n) }
        sprite :badge, facing: { still: :art_0 }, at: [0, 0]
        var :state, 0
        scene(:gallery) do
          PICTURES[1..16].each_with_index { |name, n| sprite :"statue_#{n}", facing: { still: name }, at: [n * 8, 40] }
          pool :gull, x: 0, y: 0, capacity: 2, image: :art_17
        end
        game_loop { case_var(:state) { when_val 0, :gallery } }
      end
    end
    gallery = screens(error.sprite_memory).fetch(:gallery)

    assert_includes error.message, "need #{gallery.used} bytes"
    assert_equal 18, gallery.sprites.size, "every statue, the gulls and the badge"
    assert_equal :sent_as_shown, placed(gallery, :gull).held, "as a finished build would say"
    assert_match(/scene :gallery/, error.sprite_memory.to_s)
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# A release of our own, in Wolfenstein's formats. These tests read it back the way the readers
# will, so the fixture is proven before anything is built on it.
class TestFixtureRelease < Minitest::Test
  include Wolf3DTest

  Release = Wolf3D::Fixture::Release

  def test_a_written_release_is_one_the_locator_accepts
    Dir.mktmpdir do |dir|
      Release.write(dir, set: "WL1")

      data = with_env(dir) { Wolf3D::GameData.locate(home: dir) }
      assert_equal "WL1", data.set
    end
  end

  def test_the_level_reads_back_as_the_room_we_asked_for
    release = Release.new
    grid = decode_plane(release, 0)

    assert_equal 64 * 64, grid.length
    assert_equal Release::WALL, grid[0], "top-left should be wall"
    assert_equal Release::WALL, grid[(63 * 64) + 63], "bottom-right should be wall"
    assert_equal Release::FIRST_FLOOR, grid[(32 * 64) + 32], "the middle should be floor"
    assert_equal Release::DOOR, grid[32], "a door in the north wall"
  end

  def test_the_things_are_where_the_second_plane_says
    release = Release.new
    plane = decode_plane(release, 1)
    middle = (32 * 64) + 32

    assert_equal Release::PLAYER_NORTH, plane[middle]
    assert_equal Release::GUARD_EAST, plane[middle + 2]
    assert_equal Release::GOLD_KEY, plane[release.key_cell]
    assert_equal Wolf3D::Level::PUSHWALL, plane[release.push_wall_cell]
    assert_equal 4, plane.count(&:positive?),
                 "the player, a guard, a key and a push wall — and nothing else"
  end

  # A name sits at the end of the header, so reading it proves every field before it is the
  # right width — which is how the missing four-byte tail at the end showed up.
  def test_the_level_header_is_the_right_shape_all_the_way_to_its_end
    release = Release.new
    maps, level_at = release.send(:gamemaps)
    head = maps[level_at, Release::LEVEL_HEADER_BYTES]

    assert_equal [64, 64], head[18, 4].unpack("v2")
    assert_equal "Fixture Room", head[22, 16].unpack1("Z*")
    assert_equal Release::HEADER_END, head[38, 4]
  end

  def test_the_wall_textures_are_stored_column_by_column
    chunks = vswap_chunks(Release.new)
    wall = chunks[:walls].first

    assert_equal 4096, wall.bytesize
    # Column 0 is the border, so its 64 bytes are all the border colour. If a reader transposed
    # the pixels this would be a stripe instead.
    assert_equal [0] * 64, wall[0, 64].bytes
    assert_equal 0, wall.getbyte(64), "the second column starts on the border row"
  end

  def test_the_header_says_where_sprites_and_sounds_begin
    release = Release.new(walls: 3, sprites: 2, sounds: 2)
    chunks = vswap_chunks(release)

    assert_equal 3, chunks[:walls].length
    assert_equal 2, chunks[:sprites].length
    assert_equal 2, chunks[:sounds].length
  end

  def test_a_sound_is_raw_unsigned_samples
    chunks = vswap_chunks(Release.new)
    sound = chunks[:sounds].first

    assert_equal 512, sound.bytesize
    assert(sound.bytes.all? { |b| b.between?(0, 255) })
    refute_equal 1, sound.bytes.uniq.length, "a flat sound would prove nothing"
  end

  # Measured against a real VSWAP: the pool sits before the posts, padded to keep them on a
  # word boundary. A fixture that got this backwards would teach the reader the wrong format.
  def test_a_sprite_puts_its_pixels_before_its_posts
    chunk = vswap_chunks(Release.new)[:sprites].first
    first_col, last_col = chunk[0, 4].unpack("v2")
    columns = last_col - first_col + 1
    offsets = chunk[4, columns * 2].unpack("v*")

    header_ends = 4 + (columns * 2)
    assert_operator offsets.min, :>, header_ends, "posts must come after the pool"
    assert_equal 0, offsets.min.even? ? 0 : 1, "posts start on a word boundary"

    wanted = offsets.sum do |off|
      finish, _mystery, start = chunk[off, 6].unpack("v3")
      (finish - start) / 2
    end
    assert_operator offsets.min - header_ends, :>=, wanted
  end

  def test_the_packed_art_unpacks_to_what_went_in
    release = Release.new
    graph, dictionary, head = release.send(:vgagraph)
    offsets = head.bytes.each_slice(3).map { |a, b, c| a | (b << 8) | (c << 16) }
    tree = Wolf3D::Codec::Huffman::Tree.from_dictionary(dictionary)

    table = tree.unpack(graph[offsets[0], offsets[1] - offsets[0]], 8)
    assert_equal [8, 8, 16, 4], table.unpack("v*")

    picture = tree.unpack(graph[offsets[1], offsets[2] - offsets[1]], 64)
    assert_equal (0...64).to_a, picture.bytes
  end

  private

  def decode_plane(release, plane)
    maps, level_at = release.send(:gamemaps)
    head = maps[level_at, 42]
    at = head[0, 12].unpack("V3")[plane]
    length = head[12, 6].unpack("v3")[plane]

    rlew = Wolf3D::Codec::RLEW.new(tag: Release::RLEW_TAG)
    rlew.expand(Wolf3D::Codec::Carmack.expand(maps[at, length])[2..]).unpack("v*")
  end

  def vswap_chunks(release)
    data = release.send(:vswap)
    count, first_sprite, first_sound = data[0, 6].unpack("v3")
    starts = data[6, count * 4].unpack("V*")
    lengths = data[6 + (count * 4), count * 2].unpack("v*")
    all = count.times.map { |i| data[starts[i], lengths[i]] }

    { walls: all[0...first_sprite],
      sprites: all[first_sprite...first_sound],
      sounds: all[first_sound...(count - 1)] }
  end

  def with_env(value)
    was = ENV.fetch("WOLF3D_DATA", nil)
    ENV["WOLF3D_DATA"] = value
    yield
  ensure
    was.nil? ? ENV.delete("WOLF3D_DATA") : ENV["WOLF3D_DATA"] = was
  end
end

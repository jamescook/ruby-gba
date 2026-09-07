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

  # Each chunk carries how long it comes out in four bytes in front of the packing, because
  # the packing itself does not say where it stops. Read the long way round here — offsets,
  # length, tree — so the fixture is proven before the reader that trusts it.
  def test_a_packed_chunk_says_how_long_it_comes_out
    release = Release.new
    graph, dictionary, head = release.send(:vgagraph)
    offsets = head.bytes.each_slice(3).map { |a, b, c| a | (b << 8) | (c << 16) }
    tree = Wolf3D::Codec::Huffman::Tree.from_dictionary(dictionary)

    assert_equal graph.bytesize, offsets.last, "the last offset marks the end of the file"

    packed = graph[offsets[0], offsets[1] - offsets[0]]
    length = packed[0, 4].unpack1("V")
    assert_equal Release::PICTURES.length * 4, length, "a width and a height per picture"
    assert_equal Release::PICTURES.flatten, tree.unpack(packed[4..], length).unpack("v*")
  end

  # --- a release whose pictures have names -----------------------------------------

  # THE STATUS BAR REACHES ITS ART BY NAME — the face, the numerals, the plate — and what a
  # picture is called is the one thing that differs from release to release. So a fixture
  # written as a set the reader has names for has to put its pictures at the numbers those
  # names point at. Without that the bar's own art can only be tested against somebody's copy
  # of the game.
  def test_a_named_release_puts_its_pictures_where_the_names_point
    vg = named.pictures

    assert_operator vg.picture_count, :>, Wolf3D::Vgagraph::WL6_NAMES.values.max,
                    "the table has to reach the last picture that has a name"
    assert_equal [320, 40], vg.size(:status_bar), "the steel plate along the bottom"
    assert_equal [24, 32], vg.size(:face_1a), "the face that watches you"
    assert_equal [8, 16], vg.size(:digit_0), "a numeral on the bar"
  end

  # EVERY PIXEL SAYS WHICH PICTURE IT IS, and that is what a row of twenty-four faces needs:
  # the bar reads a face by walking columns out of one wide picture, so a walk that reached one
  # face along would still come back with something that looked like a face. Here it comes back
  # with numbers that name the face it really read.
  def test_a_named_picture_says_which_one_it_is_and_where_in_it_you_are
    face = named.pictures.picture(:face_1a)
    number = Wolf3D::Vgagraph::WL6_NAMES.fetch(:face_1a)

    face.height.times do |y|
      face.width.times do |x|
        assert_equal named.send(:named_pixel, number, (y * face.width) + x), face[x, y],
                     "pixel (#{x},#{y}) came from the wrong place"
      end
    end
  end

  def test_no_two_faces_are_the_same_picture
    vg = named.pictures
    faces = (1..8).flat_map { |band| %w[a b c].map { |look| vg.picture(:"face_#{band}#{look}") } }

    assert_equal faces.length, faces.map(&:pixels).uniq.length
  end

  # THE PLATE IS THE ONE PICTURE HERE WITH AN ARRANGEMENT rather than pixels of its own. The
  # bar reads it for a layout — a line along the top and the bottom, a dark column between each
  # pair of fields, and the word inside each field — and works all three out by looking. So
  # what is asked of it is what the reader asks: that the fields come out, and that each one
  # carries a word nothing else on the plate could be mistaken for.
  def test_every_field_of_the_plate_carries_a_word_of_its_own
    art = Wolf3D::BarArt.of(named.pictures)
    refute_nil art, "a named release must be able to give the bar its art"

    words = Wolf3D::BarArt::LABEL_FIELDS.map { |f| art.label(f, Wolf3D::Palette.game)[:data] }

    assert_equal Wolf3D::BarArt::LABEL_FIELDS.length, words.uniq.length,
                 "a word cut from the wrong field would come back as one of the others"
  end

  # ...AND THE BAR LAID OUT FROM IT FITS THE SCREEN, which is what makes this a fixture OF the
  # release rather than a plate of our own: seven fields and the gaps between them come to 240,
  # and every one of them starts on an even column, because that is where the screen the bar
  # lands on will take a picture.
  def test_a_bar_laid_out_from_the_plate_fits_the_screen
    art = Wolf3D::BarArt.of(named.pictures)
    layout = Wolf3D::StatusBar.layout(art)
    widths = Wolf3D::StatusBar.widths(art)

    assert_operator layout.values.min, :>, 0, "the leftmost field needs a gap in front of it"
    assert_operator layout[:keys] + widths[:keys], :<=, Wolf3D::FirstPerson::ACROSS
    assert_empty layout.reject { |_, x| x.even? },
                 "a picture on this screen must start on an even column"
  end

  private

  # A release written as a set the reader has names for. Kept on the class because packing its
  # art is the only slow thing here and nothing changes it.
  def self.named = @named ||= Release.new(set: "WL6")
  def named = self.class.named

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

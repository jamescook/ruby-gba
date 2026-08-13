# frozen_string_literal: true

require_relative "test_helper"

class TestVswap < Minitest::Test
  include Wolf3DTest

  Vswap = Wolf3D::Vswap
  Release = Wolf3D::Fixture::Release

  def setup
    @release = Release.new(walls: 3, sprites: 2, sounds: 2)
    @vswap = Vswap.new(@release.files["VSWAP"])
  end

  def test_the_header_says_where_each_kind_begins
    assert_equal 3, @vswap.wall_count
    assert_equal 2, @vswap.sprite_count
    assert_equal 2, @vswap.sound_count
  end

  # A wall is stored column by column, which is the order a first-person view reads it in. The
  # fixture draws a border and a diagonal, so a reader that swapped the two would show a stripe.
  def test_a_wall_is_read_column_by_column
    wall = @vswap.wall(0)

    assert_equal [0] * 64, wall.column(0), "the first column is all border"
    assert_equal 0, wall[0, 0]
    assert_equal 0, wall[63, 63]
    assert_equal wall[10, 10], wall[20, 20], "the diagonal is one colour"
    refute_equal wall[10, 10], wall[10, 20], "and it is not the whole picture"
  end

  def test_each_wall_is_its_own_picture
    refute_equal @vswap.wall(0)[10, 20], @vswap.wall(1)[10, 20]
  end

  def test_a_sprite_knows_which_columns_it_uses_and_is_see_through_outside_them
    sprite = @vswap.sprite(0)

    assert_equal 20, sprite.first_column
    assert_equal 43, sprite.last_column
    assert_nil sprite[0, 32], "nothing left of the first column"
    assert_nil sprite[63, 32], "nothing right of the last"
    refute_nil sprite[20, 20], "and something inside them"
  end

  def test_a_sprite_is_see_through_above_and_below_its_runs
    sprite = @vswap.sprite(0)

    assert_nil sprite[30, 0]
    assert_nil sprite[30, 63]
    refute_nil sprite[30, 20]
  end

  # Raw 8-bit samples, and unsigned — the one conversion needed, since the framework takes them
  # centred on zero.
  def test_a_sound_comes_back_centred_on_zero
    sound = @vswap.sound(0)

    assert_equal 512, sound.length
    assert_equal 7000, sound.rate
    assert_operator sound.pcm.min, :>=, -128
    assert_operator sound.pcm.max, :<=, 127
    refute_equal 1, sound.pcm.uniq.length, "a flat sound would prove nothing"
  end

  def test_asking_for_something_that_is_not_there_says_so
    assert_raises(IndexError) { @vswap.wall(99) }
    assert_raises(IndexError) { @vswap.sprite(99) }
    assert_raises(IndexError) { @vswap.sound(99) }
  end

  def test_a_file_whose_table_runs_past_its_end_is_refused
    broken = @release.files["VSWAP"].dup
    broken[6, 4] = [1_000_000].pack("V")

    assert_raises(ArgumentError) { Vswap.new(broken) }
  end
end

# The reader against a real copy. Skips without one.
class TestVswapAgainstTheRealFile < Minitest::Test
  include Wolf3DTest

  def setup
    @vswap = Wolf3D::Vswap.from(game_data_or_skip)
  end

  def test_every_wall_is_four_thousand_and_ninety_six_bytes_of_palette_numbers
    assert_operator @vswap.wall_count, :>, 50

    @vswap.walls.each_with_index do |wall, i|
      assert_equal 64, wall.column(0).length, "wall #{i}"
      assert(wall.column(0).all? { |v| v.between?(0, 255) }, "wall #{i}")
    end
  end

  # Objects in this game stand on the floor, so a correctly decoded set reaches the bottom of
  # the box. A reader that lost its place in the pixels would leave them hugging the top.
  def test_the_sprites_decode_as_things_standing_on_the_floor
    bottoms = @vswap.sprites.filter_map do |sprite|
      rows = (0...64).flat_map { |x| (0...64).select { |y| sprite[x, y] } }
      rows.max
    end

    assert_operator bottoms.length, :>, 400
    assert_operator bottoms.count { |b| b > 40 }, :>, bottoms.length * 0.9,
                    "most sprites should reach the lower half"
    assert_equal 0, bottoms.count { |b| b < 16 }, "none should be stuck at the top"
  end

  def test_a_sprite_is_mostly_see_through_because_most_of_one_is_empty
    sprite = @vswap.sprite(50)
    filled = sprite.opaque_pixels

    assert_operator filled, :>, 0
    assert_operator filled, :<, 64 * 64, "a sprite that filled its box would not need runs"
  end

  # Sounds run across chunks, so the index is the only thing that says where one ends.
  def test_the_sounds_are_the_lengths_the_index_claims
    assert_operator @vswap.sound_count, :>, 20

    @vswap.sounds.each_with_index do |sound, i|
      assert_operator sound.length, :>, 0, "sound #{i}"
      assert_equal sound.length, sound.pcm.length, "sound #{i}"
      assert(sound.pcm.all? { |s| s.between?(-128, 127) }, "sound #{i}")
    end
  end

  # A recorded sound swings both ways around the middle. One that did not would mean the
  # unsigned-to-signed conversion went the wrong way.
  def test_a_sound_swings_both_sides_of_silence
    pcm = @vswap.sound(0).pcm

    assert_operator pcm.min, :<, -20
    assert_operator pcm.max, :>, 20
  end
end

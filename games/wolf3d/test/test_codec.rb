# frozen_string_literal: true

require_relative "test_helper"

class TestRLEW < Minitest::Test
  include Wolf3DTest

  TAG = 0xABCD
  RLEW = Wolf3D::Codec::RLEW.new(tag: TAG)

  def test_a_run_becomes_a_run_and_comes_back
    words = [7] * 40
    packed = RLEW.compress(pack(words))

    assert_equal pack([TAG, 40, 7]), packed
    assert_equal words, unpack(RLEW.expand(packed))
  end

  def test_short_runs_are_left_alone_because_a_run_costs_three_words
    words = [1, 2, 2, 2, 3]

    assert_equal words, unpack(RLEW.compress(pack(words)))
  end

  # A word that happens to equal the tag cannot be written plainly — it would be read back as
  # the start of a run.
  def test_a_word_equal_to_the_tag_survives
    words = [1, TAG, 2, TAG, TAG]
    packed = RLEW.compress(pack(words))

    assert_equal words, unpack(RLEW.expand(packed))
  end

  def test_the_tag_is_whatever_the_file_says_it_is
    words = [5] * 10

    [0x0000, 0xABCD, 0xFFFF].each do |tag|
      codec = Wolf3D::Codec::RLEW.new(tag: tag)
      packed = codec.compress(pack(words))

      assert_equal words, unpack(codec.expand(packed)), "tag 0x#{tag.to_s(16)}"
    end
  end

  private

  def pack(words) = words.pack("v*")
  def unpack(data) = data.unpack("v*")
end

class TestCarmack < Minitest::Test
  include Wolf3DTest

  Carmack = Wolf3D::Codec::Carmack

  def test_plain_words_survive
    assert_round_trip [1, 2, 3, 4, 5]
  end

  def test_a_repeat_close_behind_becomes_a_near_pointer
    words = [1, 2, 3, 4] + [1, 2, 3, 4]
    packed = Carmack.compress(pack(words))

    assert_includes packed.bytes, Carmack::NEAR
    assert_round_trip words
  end

  # A far pointer is the only way to reach something more than 255 words back, so this is the
  # case a near-window-only search would silently miss.
  def test_a_repeat_far_behind_becomes_a_far_pointer
    words = [9, 8, 7, 6, 5] + Array.new(400) { |i| i } + [9, 8, 7, 6, 5]
    packed = Carmack.compress(pack(words))

    assert_includes packed.bytes, Carmack::FAR
    assert_round_trip words
  end

  # A word carrying a marker in its HIGH byte is data, not a pointer, and needs the zero-count
  # escape to say so.
  def test_a_word_that_looks_like_a_pointer_survives
    assert_round_trip [0xA700, 0xA7FF, 0xA812, 0xA8FF, 0x00A7, 0x00A8]
  end

  # The original copies a word at a time, so a copy may quote words it is still writing.
  def test_a_copy_may_overlap_what_it_is_writing
    stream = +"".b
    stream << [12].pack("v")          # six words out
    stream << [1].pack("v") << [2].pack("v")
    stream << [(Carmack::NEAR << 8) | 4].pack("v") << [2].pack("C")

    assert_equal [1, 2, 1, 2, 1, 2], unpack(Carmack.expand(stream))
  end

  # Our compressor may never emit one, so decoding a hand-built far pointer is its own check.
  def test_a_hand_built_far_pointer_decodes
    stream = +"".b
    stream << [10].pack("v")          # five words out
    stream << [7].pack("v") << [8].pack("v") << [9].pack("v")
    stream << [(Carmack::FAR << 8) | 2].pack("v") << [0].pack("v")

    assert_equal [7, 8, 9, 7, 8], unpack(Carmack.expand(stream))
  end

  def test_a_truncated_stream_is_refused_rather_than_guessed_at
    stream = [100].pack("v") << [1].pack("v")

    assert_raises(ArgumentError) { Carmack.expand(stream) }
  end

  def test_a_copy_reaching_before_the_start_is_refused
    stream = +"".b
    stream << [4].pack("v")
    stream << [1].pack("v")
    stream << [(Carmack::NEAR << 8) | 1].pack("v") << [50].pack("C")

    assert_raises(ArgumentError) { Carmack.expand(stream) }
  end

  private

  def pack(words) = words.pack("v*")
  def unpack(data) = data.unpack("v*")

  def assert_round_trip(words)
    assert_equal words, unpack(Carmack.expand(Carmack.compress(pack(words))))
  end
end

# The codecs against the world rather than against themselves. Skips without a copy of the game.
class TestCodecAgainstRealMaps < Minitest::Test
  include Wolf3DTest

  def test_every_level_expands_to_a_64_by_64_grid_and_round_trips
    data = game_data_or_skip
    maphead = data.read("MAPHEAD")
    gamemaps = data.read("GAMEMAPS")
    rlew = Wolf3D::Codec::RLEW.new(tag: maphead[0, 2].unpack1("v"))
    offsets = maphead[2..].unpack("V*").take_while(&:positive?)

    refute_empty offsets

    offsets.each_with_index do |off, level|
      head = gamemaps[off, 42]
      plane_offs = head[0, 12].unpack("V3")
      plane_lens = head[12, 6].unpack("v3")

      (0..1).each do |plane|
        packed = gamemaps[plane_offs[plane], plane_lens[plane]]
        carmacked = Wolf3D::Codec::Carmack.expand(packed)
        grid = rlew.expand(carmacked[2..])

        assert_equal 8192, grid.bytesize, "level #{level} plane #{plane}"
        assert_equal 8192, carmacked[0, 2].unpack1("v"), "level #{level} plane #{plane} header"
        assert_equal grid, rlew.expand(rlew.compress(grid))
      end
    end
  end
end

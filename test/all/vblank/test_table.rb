# frozen_string_literal: true

require "test_helper"

# The `table` verb: a build-time Ruby array shipped as read-only ROM data, read at
# run time by a Value index. These assert the observable value a lookup returns on
# the reference interpreter — the fast oracle — including signedness and the
# out-of-range safety rule. The hardware lowering is checked with the emulator in
# test/lowering/gba/vblank/test_table_cartridge.rb.
class TestTable < Minitest::Test
  private def interpret(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    game_player.run(b.program)
  end

  def test_reads_a_value_at_a_constant_index
    i = interpret do
      squares = table :squares, [0, 1, 4, 9, 16, 25], width: :byte
      var :out, 0
      set! :out, squares[3]
      halt
    end
    assert_equal 9, i[:out]
  end

  def test_reads_at_a_runtime_index
    i = interpret do
      t = table :t, [10, 20, 30, 40], width: :byte
      idx = var :idx, 2
      var :out, 0
      set! :out, t[idx]
      halt
    end
    assert_equal 30, i[:out]
  end

  # A table bigger than a Game Boy Color bank is kept in parts, so the entries either side of
  # each place one part ends and the next begins are the ones to read. Each entry is its own
  # index, scrambled, so an entry read from the wrong place reads as the wrong number.
  def test_a_big_table_reads_every_entry_either_side_of_where_its_parts_meet
    places = [0, 4095, 4096, 8191, 8192, 11_999]
    i = interpret do
      t = table :big, (0...12_000).map { |n| (n * 7919) % 65_536 }, width: :half
      at = var :at, 0
      places.each_with_index do |place, n|
        var :"out_#{n}", 0
        at.set! place
        set! :"out_#{n}", t[at]
      end
      halt
    end
    places.each_with_index do |place, n|
      assert_equal (place * 7919) % 65_536, i[:"out_#{n}"], "entry #{place}"
    end
  end

  # Tables whose entries run past 65536 bytes, read by an index the game works out: a table of
  # halves whose length is a power of two (an index past it goes round), one of bytes and one of
  # whole numbers whose lengths are not (an index past either end is held there). The places are
  # the edges of what two bytes of index, or of offset, can say.
  def test_a_table_past_sixty_four_kilobytes_reads_the_entry_named
    halves = Array.new(131_072) { |n| n % 65_521 }
    bytes = Array.new(70_000) { |n| ((n * 37) + (n / 251)) % 256 }
    words = Array.new(20_000) { |n| (n * 104_729) - 1_000_000_000 }
    reads = { halves: [27, 32_767, 32_768, 46_363, 65_535, 65_536, 100_000, 131_071, 131_072, -1],
              bytes: [16_384, 65_535, 65_536, 69_999, 70_000, -5],
              words: [16_383, 16_384, 19_999, 20_000] }
    i = interpret do
      tables = { halves: table(:halves, halves, width: :half, signed: false),
                 bytes: table(:bytes, bytes, width: :byte, signed: false), words: table(:words, words, width: :word) }
      at = var :at, 0
      reads.each do |name, places|
        places.each_with_index do |place, n|
          var :"#{name}_#{n}", 0
          at.set! place
          set! :"#{name}_#{n}", tables.fetch(name)[at]
        end
      end
      halt
    end
    { halves: ->(at) { halves[at % halves.length] }, bytes: ->(at) { bytes[at.clamp(0, bytes.length - 1)] },
      words: ->(at) { words[at.clamp(0, words.length - 1)] } }.each do |name, entry|
      reads.fetch(name).each_with_index do |place, n|
        assert_equal entry[place], i[:"#{name}_#{n}"], "#{name} entry #{place}"
      end
    end
  end

  def test_signed_values_round_trip
    i = interpret do
      t = table :sines, [0, 127, -128, -1], width: :byte # signed is inferred (a negative present)
      var :out, 0
      set! :out, t[2]
      halt
    end
    assert_equal(-128, i[:out])
  end

  # A halfword sine table scaled to +/-256: read a known entry.
  def test_a_build_time_sine_table
    i = interpret do
      sin = table :sin, (0...256).map { |a| (Math.sin(a * Math::PI / 128) * 256).round }, width: :half
      var :q, 64
      var :out, 0
      set! :out, sin[:q] # sin at a quarter turn (64/256) is the peak, +256
      halt
    end
    assert_equal 256, i[:out]
  end

  def test_power_of_two_table_wraps_the_index
    i = interpret do
      t = table :t, [100, 200, 300, 400], width: :half # 4 entries: index 5 wraps to 1
      var :out, 0
      set! :out, t[5]
      halt
    end
    assert_equal 200, i[:out]
  end

  def test_non_power_of_two_table_clamps_the_index
    i = interpret do
      t = table :t, [7, 8, 9], width: :half # 3 entries: past-the-end clamps to the last, below-zero to the first
      var :hi, 0
      var :lo, 0
      set! :hi, t[9]
      set! :lo, t[-4]
      halt
    end
    assert_equal 9, i[:hi]
    assert_equal 7, i[:lo]
  end

  # --- Guardrails ---

  def test_a_value_too_big_for_the_width_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { table :t, [0, 300], width: :byte } # 300 > 255
    end
    assert_match(/does not fit/, err.message)
  end

  def test_a_bad_width_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { table :t, [1, 2], width: :quad }
    end
    assert_match(/:byte, :half, or :word/, err.message)
  end

  def test_values_that_are_not_numbers_are_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { table :t, [1, "two"], width: :half }
    end
    assert_match(/numbers only/, err.message)
  end

  # A Float in the table is not an error — it says the table holds numbers with a
  # fraction. They are stored multiplied up, and every read carries the fraction, so a
  # sine table can be written as plain trigonometry.
  def test_a_table_of_floats_holds_numbers_with_a_fraction
    b = Builder.new
    t = b.instance_eval { table :halves, [0.5, -1.25] }

    assert_predicate t[0], :fraction?
    assert_equal 16, t[0].fraction_bits

    stored = b.program.walk.find { |n| n.kind == :table }
    assert_equal [0.5 * (1 << 16), -1.25 * (1 << 16)], stored.values
    assert_equal :word, stored.width, "a whole number plus 16 bits of fraction needs a word"
  end
end

# frozen_string_literal: true

require "test_helper"

# A ROUTINE'S BIG NUMBERS, KEPT IN A TABLE AFTER ITS LAST INSTRUCTION.
#
# The chip puts a number in a register with one instruction only when the number is a single
# byte, shifted; anything else is built a byte at a time, up to four instructions. The other
# way is to keep the number as a word of data beside the code and READ it, which is one
# instruction whatever the number is. A routine kept in the console's quick memory is
# competing for 32K with everything else that wants to run fast, so its numbers go in a table.
#
# This file is the table on its own: what is read, what is still built, and what stops the
# build. That a whole game comes out right is test_quick_memory_numbers.rb.
class TestNumberTable < Minitest::Test
  A = RubyGBA::IR::Backends::GBA::ASM
  Emit = RubyGBA::IR::Backends::GBA::Emit
  LoweringError = RubyGBA::IR::Backends::GBA::LoweringError

  THREE = 0x03006E1C # three bytes of it are not nought, and neither is its opposite's
  FOUR = 0x12345678
  HEADER = RubyGBA::Console::Hardware::ROM_START + RubyGBA::Cartridge::ROM::ENTRY_OFFSET

  private def words_of(emitter) = emitter.code.unpack("V*")

  # Is this a read of a word ahead of it, and if so into which register and how far on?
  private def read_from_table(word)
    return nil unless (word & 0xFFFF0000) == 0xE59F0000

    { register: (word >> 12) & 0xF, ahead: word & 0xFFF }
  end

  # The word a read at instruction +index+ names: the chip counts from two instructions on.
  private def word_named_by(words, index)
    read = read_from_table(words[index]) or flunk format("not a read from a table: 0x%08X", words[index])
    words[index + 2 + (read[:ahead] / 4)]
  end

  # A routine measured at +measured_bytes+ with every number built, in which a load within
  # +read_within+ of that measured end is read — the whole routine unless a test says.
  private def routine(measured_bytes: 64, read_within: measured_bytes)
    emitter = Emit.new
    emitter.open_number_table(measured_bytes: measured_bytes, read_within: read_within, routine: :work)
    yield emitter
    emitter.emit(A.pop(15))
    emitter.close_number_table
    emitter
  end

  # --- what is read ---

  def test_a_number_of_three_instructions_is_one_read_and_a_word_after_the_routine
    words = words_of(routine { |e| e.emit_number(3, THREE) })

    assert_equal 3, words.length, "the read, the return, and the word"
    assert_equal 3, read_from_table(words[0])[:register]
    assert_equal THREE, word_named_by(words, 0)
    assert_equal A.pop(15).unpack1("V"), words[1], "the table is past the last instruction, never in the way"
  end

  def test_a_number_of_four_instructions_is_one_read_too
    words = words_of(routine { |e| e.emit_number(0, FOUR) })

    assert_equal FOUR, word_named_by(words, 0)
  end

  def test_the_same_number_read_twice_is_kept_once
    words = words_of(routine do |e|
      e.emit_number(0, THREE)
      e.emit_number(1, FOUR)
      e.emit_number(2, THREE)
    end)

    assert_equal [THREE, FOUR, THREE], [0, 1, 2].map { |index| word_named_by(words, index) }
    assert_equal 3 + 1 + 2, words.length, "three reads, the return, two words"
  end

  # --- what is still built ---

  def test_a_number_the_chip_can_build_in_one_or_two_instructions_is_still_built
    words = words_of(routine do |e|
      e.emit_number(0, 0xFF)
      e.emit_number(1, 0xFFFFFFFF)
      e.emit_number(2, 0x04000000 | 0xD4)
    end)

    assert_equal 4 + 1, words.length, "one, one and two instructions, the return, and no table"
    assert(words.none? { |word| read_from_table(word) })
  end

  def test_with_no_table_open_every_number_is_built
    emitter = Emit.new
    emitter.emit_number(0, THREE)

    assert_equal A.load_immediate(0, THREE), emitter.code
  end

  # A read can name a word about four thousand bytes ahead and no further, so the build
  # says how near the end of its routine a load has to be, and one further off is built the
  # way it always was.
  def test_a_load_too_far_from_the_end_of_its_routine_is_built
    emitter = routine(measured_bytes: 4824, read_within: 3000) do |e|
      e.emit_number(0, THREE) # 4824 bytes from the end as measured
      e.emit(A.nop * 1200)
      e.emit_number(1, THREE) # ...and twelve from it
    end
    words = words_of(emitter)

    assert_nil read_from_table(words[0]), "the early one is built"
    late = 3 + 1200
    assert_equal 1, read_from_table(words[late])[:register], "the late one is read"
    assert_equal THREE, word_named_by(words, late)
  end

  # THE LINE IS COUNTED IN THE ROUTINE AS IT WAS MEASURED, with every number built — not in
  # the shorter routine the reads leave behind. Three loads of twelve bytes each, measured
  # at 0, 12 and 24 of a 36-byte routine, and a line 24 bytes from the end: the first is
  # past it and the other two are inside. The third really sits at 16, not 24, because the
  # second became a read; it is judged by where it was measured all the same.
  def test_the_line_is_where_a_load_was_measured_not_where_the_reads_left_it
    emitter = routine(measured_bytes: 36, read_within: 24) do |e|
      e.emit_number(0, THREE)
      e.emit_number(1, THREE + 1)
      e.emit_number(2, THREE + 2)
    end
    words = words_of(emitter)

    assert_nil read_from_table(words[0]), "the first is built: three instructions"
    assert_equal [THREE + 1, THREE + 2], [3, 4].map { |index| word_named_by(words, index) }
  end

  # --- what stops the build ---

  # Whether a load is read is settled from the size its routine was measured at. A routine
  # that ran past that would leave a read naming a word it cannot reach, and a read like
  # that is a wrong number with nothing to say so.
  def test_a_routine_that_ran_past_what_it_was_measured_at_stops_the_build
    error = assert_raises(LoweringError) do
      routine(measured_bytes: 64) do |e|
        e.emit_number(0, THREE)
        e.emit(A.nop * 1200)
      end
    end
    assert_match(/:work/, error.message, "it names the routine")
    assert_match(/furthest a read can reach/, error.message)
  end

  def test_a_second_table_cannot_be_opened_inside_the_first
    emitter = Emit.new
    emitter.open_number_table(measured_bytes: 64, read_within: 64, routine: :outer)

    assert_raises(LoweringError) do
      emitter.open_number_table(measured_bytes: 64, read_within: 64, routine: :inner)
    end
  end

  # --- addresses that are not known until everything is placed ---

  def test_the_address_of_data_in_the_cartridge_is_read_from_the_table_once_it_is_known
    emitter = routine { |e| e.emit_load_data_address(2, :picture) }
    emitter.data_blobs[:picture] = "\x01\x02\x03\x04".b
    emitter.emit_data_region
    emitter.resolve_fixups
    words = words_of(emitter)

    assert_equal 2, read_from_table(words[0])[:register]
    assert_equal HEADER + emitter.data_positions.fetch(:picture), word_named_by(words, 0)
  end

  def test_the_address_of_a_place_in_the_code_is_read_from_the_table_once_it_is_known
    emitter = routine { |e| e.emit_load_label_address(12, "elsewhere") }
    emitter.place_label("elsewhere")
    emitter.emit(A.nop)
    emitter.resolve_fixups
    words = words_of(emitter)

    assert_equal HEADER + emitter.labels.fetch("elsewhere"), word_named_by(words, 0)
  end

  def test_with_no_table_open_an_address_is_the_four_instructions_it_always_was
    emitter = Emit.new
    emitter.emit_load_data_address(2, :picture)

    assert_equal 4, words_of(emitter).length
  end

  # --- what the build is told, table or no table ---

  # The first pass of a build measures every routine with nothing moved and no table open.
  # It still has to say which loads a table COULD take, so the routine can be charged for
  # the size it will really come to.
  def test_every_load_a_table_could_take_is_noted_with_no_table_open
    emitter = Emit.new
    emit_one_load_of_each_kind(emitter)

    assert_equal [[4, 3], [16, 4], [32, 4]], emitter.number_loads.map { |load| [load.pos, load.instructions] }
  end

  # ...and with one open, where each is a single read, so they sit closer together but are
  # still noted as the instructions they would have been built from.
  def test_every_load_a_table_takes_is_noted_too
    emitter = routine { |e| emit_one_load_of_each_kind(e) }

    assert_equal [[4, 3], [8, 4], [12, 4]], emitter.number_loads.map { |load| [load.pos, load.instructions] }
  end

  # Two loads of one number are noted as the same word, which is what lets the build count
  # one word of table for the pair.
  def test_two_loads_of_one_number_are_noted_as_the_same_word
    emitter = Emit.new
    emitter.emit_number(0, THREE)
    emitter.emit_number(1, THREE)
    emitter.emit_load_data_address(2, :picture)
    emitter.emit_load_data_address(3, :picture)
    emitter.emit_load_label_address(4, :picture)

    words = emitter.number_loads.map(&:word)
    assert_equal words[0], words[1]
    assert_equal words[2], words[3]
    assert_equal 3, words.uniq.size, "a place in the code and a blob of the same name are different words"
  end

  private

  # One number small enough to build, then one load of each kind a table could take.
  def emit_one_load_of_each_kind(emitter)
    emitter.emit_number(0, 0xFF)
    emitter.emit_number(0, THREE)
    emitter.emit_load_data_address(1, :picture)
    emitter.emit_number(0, FOUR)
  end
end

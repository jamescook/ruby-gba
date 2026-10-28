# frozen_string_literal: true

require "test_helper"

# A TABLE BIGGER THAN A BANK. The cartridge is seen in 32K banks, and the next bank's first byte is
# not the byte after this bank's last, so a table that comes to more than a bank is cut into parts,
# each in whatever bank it fits. The checked run holds every variable and list to the interpreter,
# so an entry read from the wrong part, or the wrong place in its part, shows.
class TestSNESBigTables < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Build = VBlank::IR::Build

  # Whole words, four bytes each: 12000 of them are 48000 bytes, half again a bank. The numbers
  # differ entry from entry, and run past what a half holds, so each is kept whole.
  WORDS = Array.new(12_000) { |i| (i * 100_003) - 600_000_000 }
  # Bytes, one each: 70000 of them, more than two banks, and more than a 16-bit index reaches.
  BYTES = Array.new(70_000) { |i| ((i * 37) + (i / 251)) % 256 }

  private def checked(*body)
    program = Build.program(*body, Build.loop_(Build.wait_vblank))
    program.console = :snes
    SNES::CheckedRun.new.run(program, frames: 2)
  end

  private def read(variable, table, index) = Build.set(variable, Build.table_get(table, Build.int(index)))

  # Entries from the first part, the last, either side of each place one part ends, and an index
  # past the end, which reads the last entry as it does in any table.
  def test_entries_of_a_table_bigger_than_a_bank_read_from_every_part
    picks = [0, 4095, 4096, 8191, 8192, 11_999, 12_500]
    run = checked(Build.table(:numbers, WORDS, width: :word, signed: true),
                  *picks.each_with_index.map { |at, i| read(:"w#{i}", :numbers, at) })

    assert_equal [WORDS[0], WORDS[4095], WORDS[4096], WORDS[8191], WORDS[8192], WORDS[11_999], WORDS[11_999]],
                 picks.each_index.map { |i| run[:"w#{i}"] }
  end

  # A table of bytes past 65536 entries: its index is read whole, not cut to sixteen bits.
  def test_a_byte_table_past_sixteen_bits_of_index_reads_the_entry_named
    picks = [16_383, 16_384, 65_535, 65_536, 69_999]
    run = checked(Build.table(:bytes, BYTES, width: :byte, signed: false),
                  *picks.each_with_index.map { |at, i| read(:"b#{i}", :bytes, at) })

    assert_equal picks.map { |at| BYTES[at] }, picks.each_index.map { |i| run[:"b#{i}"] }
  end

  # Signed halves and signed bytes read back with their sign, at an index the game works out as
  # it runs. The halves are 32768 of them, a power of two, so an index of -1 goes round to the
  # last; the bytes are not, so 90000 is held to the last.
  def test_signed_halves_and_bytes_of_split_tables_read_at_an_index_worked_out
    halves = Array.new(32_768) { |i| ((i * 7) % 65_536) - 32_768 }
    signed_bytes = Array.new(40_000) { |i| ((i * 13) % 256) - 128 }
    run = checked(Build.table(:halves, halves, width: :half, signed: true),
                  Build.table(:signed_bytes, signed_bytes, width: :byte, signed: true),
                  Build.set(:at, 20_001),
                  Build.set(:h0, Build.table_get(:halves, Build.var_ref(:at))),
                  Build.set(:h1, Build.table_get(:halves, Build.binop(:-, Build.int(0), Build.int(1)))),
                  Build.set(:s0, Build.table_get(:signed_bytes, Build.var_ref(:at))),
                  Build.set(:s1, Build.table_get(:signed_bytes, Build.binop(:*, Build.var_ref(:at), Build.int(5)))))

    assert_equal [halves[20_001], halves[32_767], signed_bytes[20_001], signed_bytes[39_999]],
                 [run[:h0], run[:h1], run[:s0], run[:s1]]
  end

  # A run copied into a list that starts in one part and ends in the next.
  def test_a_run_copied_across_the_end_of_a_part_holds_every_entry
    run = checked(Build.table(:numbers, WORDS, width: :word, signed: true),
                  Build.list_new(:run, 8),
                  Build.list_copy(:run, table: :numbers, at: Build.int(4092), count: 8),
                  *Array.new(8) { |i| Build.set(:"r#{i}", Build.list_get(:run, Build.int(i))) })

    assert_equal WORDS[4092, 8], Array.new(8) { |i| run[:"r#{i}"] }
  end

  # A run that would start past the end is held inside the table, as in any table: the last 8.
  def test_a_run_copied_from_past_the_end_holds_the_last_entries
    run = checked(Build.table(:numbers, WORDS, width: :word, signed: true),
                  Build.list_new(:run, 8),
                  Build.list_copy(:run, table: :numbers, at: Build.int(20_000), count: 8),
                  *Array.new(8) { |i| Build.set(:"r#{i}", Build.list_get(:run, Build.int(i))) })

    assert_equal WORDS.last(8), Array.new(8) { |i| run[:"r#{i}"] }
  end

  # A part holds 4096 whole words of its own, and no more of the next, so a longer run is refused.
  def test_a_run_longer_than_a_part_is_refused_in_plain_words
    program = Build.program(Build.table(:numbers, WORDS, width: :word, signed: true),
                            Build.list_new(:run, 5000),
                            Build.list_copy(:run, table: :numbers, at: Build.int(0), count: 5000),
                            Build.loop_(Build.wait_vblank))
    program.console = :snes

    error = assert_raises(SNES::LoweringError) { SNES.new.build(program) }
    assert_match(/a maximum of 4096 entries/, error.message)
  end
end

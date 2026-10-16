# frozen_string_literal: true

require "test_helper"

# A routine kept in the console's quick memory reads its big numbers from a table at its own
# end, where a routine in the cartridge builds each one an instruction at a time. The table
# is the cheaper of the two there, and the room it gives back is room for another routine.
#
# The thing to be sure of is that A READ GETS THE NUMBER IT WAS WRITTEN FOR. A read says how
# far ahead its word is, and the routine is copied from the cartridge to the quick memory
# before it runs — so a word of the wrong kind, a distance one word out, or a table left
# behind by the copy would each hand a routine a number that is plausible and wrong.
class TestQuickMemoryNumbers < Minitest::Test
  runs_on :reference

  PLAIN = 0x12345678
  QUICK_MEMORY = 0x03000000...0x03008000
  CARTRIDGE = 0x08000000...0x0A000000

  private def program_of(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # The words of routine +name+, and the numbers its reads read: each read says how far past
  # itself its word is, counting from two instructions on.
  private def words_read_by(backend, name)
    span = backend.func_ranges.fetch(name)
    words = backend.code[span].unpack("V*")
    words.each_with_index.filter_map do |word, index|
      words.fetch(index + 2 + ((word & 0xFFF) / 4)) if table_read?(word)
    end
  end

  # LDR reg, [pc, #n]: the one instruction that reads a word a fixed distance ahead.
  private def table_read?(word) = (word & 0xFFFF0000) == 0xE59F0000

  private def reads_in(backend, name)
    backend.code[backend.func_ranges.fetch(name)].unpack("V*").count { |word| table_read?(word) }
  end

  # One routine that needs all three kinds of number: a plain one, the address of a list
  # (which is in the quick memory), and the address of a table (which is in the cartridge).
  #
  # The list is filled BEFORE the game loop, by code that stays in the cartridge and builds
  # the list's address, and the routine only reads it. Were the routine to write the item
  # and read it back, both would go through the same word of its table, and any address
  # that can be written to would hand back what was put there.
  #
  # The first list is there only to move the second one along: with nothing before it a list
  # starts on an address the chip builds in two instructions, which no table would take.
  private def program_with_every_kind(fast:)
    program_of do
      screen :bitmap
      big = var :big, 0
      kept = var :kept, 0
      found = var :found, 0
      steps = table :steps, [3, 1, 4, 1, 5, 9, 2, 6], width: :byte
      pad = list :pad, capacity: 5
      trail = list :trail, capacity: 9
      pad.push 1
      trail.push 77
      func(:work, fast: fast) do
        big.set! PLAIN
        kept.set! trail[0]
        found.set! steps[5]
      end
      game_loop { call :work }
    end
  end

  def test_a_quick_memory_routine_reads_each_kind_of_number_from_its_table
    program = program_with_every_kind(fast: true)
    backend = GBA.new
    backend.lower(program)
    read = words_read_by(backend, :work)

    assert_includes read, PLAIN, "the plain number is a word of the table"
    assert(read.any? { |word| QUICK_MEMORY.cover?(word) }, "an address in the quick memory is: #{hex(read)}")
    assert(read.any? { |word| CARTRIDGE.cover?(word) }, "an address in the cartridge is: #{hex(read)}")
  end

  # ...and each of them is the right number once the routine has been copied and run.
  def test_the_numbers_a_quick_memory_routine_reads_are_right_on_the_console
    program = program_with_every_kind(fast: true)
    oracle = Reference.new.run(program, frames: 3)
    console = console_after(program, frames: 6)

    assert_equal PLAIN, oracle[:big]
    assert_equal [PLAIN, 77, 9], [console.var(:big), console.var(:kept), console.var(:found)]
    assert_equal [oracle[:big], oracle[:kept], oracle[:found]],
                 [console.var(:big), console.var(:kept), console.var(:found)]
  end

  # A routine left in the cartridge builds every number, as it always did: there, a read
  # costs more time than the instructions it replaces.
  def test_a_cartridge_routine_keeps_no_table
    backend = GBA.new
    backend.lower(program_with_every_kind(fast: false))

    assert_equal 0, reads_in(backend, :work)
  end

  # A READ REACHES 4K AND NO FURTHER, and the table is at the routine's end. So in a long
  # routine a number near the top is built and the same number near the bottom is read —
  # and both have to be the number.
  private def long_program
    program_of do
      screen :bitmap
      first = var :first, 0
      last = var :last, 0
      filler = var :filler, 0
      func(:work, fast: true) do
        first.set! PLAIN
        600.times { filler.add! 1 }
        last.set! PLAIN
      end
      game_loop { call :work }
    end
  end

  def test_a_long_routine_builds_what_it_cannot_reach_and_reads_what_it_can
    backend = GBA.new
    backend.lower(long_program)

    assert_operator backend.func_ranges.fetch(:work).size, :>, 4096, "the routine is longer than a read reaches"
    assert_equal [PLAIN], words_read_by(backend, :work), "only the load near the end is a read"
  end

  def test_a_number_is_right_at_both_ends_of_a_long_routine
    program = long_program
    oracle = Reference.new.run(program, frames: 3)
    console = console_after(program, frames: 6)

    assert_equal [PLAIN, PLAIN], [oracle[:first], oracle[:last]]
    assert_equal [PLAIN, PLAIN], [console.var(:first), console.var(:last)]
  end

  # A ROUTINE THAT ONLY LOOKS TOO LONG. Built an instruction at a time this one is well past
  # what a read reaches, so its first number used to be built. But a routine SHRINKS as its
  # numbers become reads, and this one is nearly all numbers: read, it is about half the
  # length, and its first number is in reach of its end after all. The build counts the
  # shrinking it is sure of before it asks whether a load reaches.
  private def shrinking_program(fast: true)
    program_of do
      screen :bitmap
      first = var :first, 0
      rest = var :rest, 0
      func(:work, fast: fast) do
        first.set! PLAIN
        SHRINKING.times { |n| rest.set! PLAIN + 1 + n }
      end
      game_loop { call :work }
    end
  end

  SHRINKING = 260

  def test_a_routine_that_shrinks_into_reach_reads_every_number
    built = GBA.new
    built.lower(shrinking_program(fast: false))
    backend = GBA.new
    backend.lower(shrinking_program)

    assert_operator built.func_ranges.fetch(:work).size, :>, 4096, "with every number built it is too long"
    read = words_read_by(backend, :work)
    assert_equal SHRINKING + 1, read.size, "every number is read"
    assert_equal [PLAIN, PLAIN + SHRINKING], [read.first, read.last]
    charged, emitted = backend.charged_and_emitted_sizes.fetch(:work)
    assert_equal emitted, charged, "and it is charged for the size it shrank to"
  end

  def test_the_numbers_of_a_routine_that_shrank_are_right_on_the_console
    console = console_after(shrinking_program, frames: 6)

    assert_equal [PLAIN, PLAIN + SHRINKING], [console.var(:first), console.var(:rest)]
  end

  # A READ THAT CANNOT REACH ITS WORD STOPS THE BUILD. Whether a load reaches is settled from
  # the most its routine was said it could come to, so the one way to a read that does not
  # reach is that promise being too small — a fault in the build, and one that would
  # otherwise hand the routine whatever word sits 4K past the read. Here the promise is made
  # too small on purpose: the load at the top is taken for a read, and the routine then runs
  # on for longer than a read reaches.
  def test_a_read_that_cannot_reach_its_table_stops_the_build
    backend = GBA.new
    backend.define_singleton_method(:number_table_for) do |name|
      super(name)&.with(measured_bytes: 64, read_within: 64)
    end

    error = assert_raises(GBA::LoweringError) { backend.lower(long_program) }
    assert_match(/:work/, error.message, "it names the routine")
    assert_match(/furthest a read can reach/, error.message)
  end

  # WHAT A ROUTINE IS CHARGED STILL HAS TO COVER WHAT IT COMES OUT AT. The chooser takes the
  # table's saving off before the table exists, and a saving taken that the real pass did not
  # make is a build that stops at the very end, on a game that fits (see
  # TestFastCodePlacement#test_a_routine_is_charged_at_least_what_it_comes_out_at). Here the
  # routine has what the saving is worked out from: one number named several times, which
  # shares a word, and a call out to the cartridge, whose address is a word too.
  def test_a_routine_with_a_table_is_charged_at_least_what_it_comes_out_at
    program = program_of do
      screen :bitmap
      a = var :a, 0
      b = var :b, 0
      func(:cold, fast: false) { b.add! 1 }
      func(:work, fast: true) do
        3.times { a.set! PLAIN }
        call :cold
        a.set! PLAIN + 1
      end
      game_loop { call :work }
    end
    backend = GBA.new
    backend.lower(program)
    charged, emitted = backend.charged_and_emitted_sizes.fetch(:work)

    plain = words_read_by(backend, :work).reject { |word| QUICK_MEMORY.cover?(word) || CARTRIDGE.cover?(word) }

    assert_equal [PLAIN, PLAIN, PLAIN, PLAIN + 1], plain
    assert_operator charged, :>=, emitted
    assert_operator charged - emitted, :<=, 16, "and no more than the slack it always had"
  end

  private

  # The console after +frames+ frames of +program+, able to say what each variable holds.
  def console_after(program, frames:)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "NUMBERS", maker: "01", built: backend.build_record(program))
    assert_emulator_loads_rom(rom, frames: frames, vars: backend.var_addresses)
  end

  def hex(words) = words.map { |word| format("%08X", word) }.join(" ")
end

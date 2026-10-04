# frozen_string_literal: true

require "test_helper"

# A RUN OF LIST ITEMS SET TO ONE VALUE (list_fill) on the console, against the interpreter.
# The console writes the run a word at a time with a byte at each ragged end, so what is worth
# checking is every item around both ends, for each width an item can be: a run that starts
# part way into a word and stops part way into another is where a lead or a tail goes wrong.
class TestListFill < Minitest::Test
  include RubyGBA::IR::Build

  ITEMS = 13

  # A list of ITEMS items of +width+, all 1, with +fill+ (keywords of list_fill) applied, and
  # every item read into a variable :item0, :item1, ... so both backends can be asked.
  def filled(width, **fill)
    program(
      list_new(:items, ITEMS, width: width),
      *Array.new(ITEMS) { list_push(:items, 1) },
      list_fill(:items, **fill),
      *Array.new(ITEMS) { |i| set(:"item#{i}", list_get(:items, i)) },
      halt,
    )
  end

  def items_on_console(prog)
    backend = GBA.new
    rom = RubyGBA::Cartridge::ROM.assemble(backend.lower(prog), title: "LISTFILL")
    v = assert_emulator_loads_rom(rom, frames: 2, vars: backend.var_addresses)
    Array.new(ITEMS) { |i| v.var(:"item#{i}") }
  end

  def items_on_interpreter(prog)
    i = Reference.new.run(prog)
    Array.new(ITEMS) { |n| i[:"item#{n}"] }
  end

  # Items 3 to 9 set to +value+: from part way into the first word to part way into the third.
  def assert_run_filled(width, value)
    prog = filled(width, from: 3, count: 7, value: value)
    want = Array.new(ITEMS) { |i| (3...10).cover?(i) ? value : 1 }

    assert_equal want, items_on_interpreter(prog)
    assert_equal want, items_on_console(prog)
  end

  def test_a_run_of_byte_items_is_filled_the_same_on_both = assert_run_filled(:byte, -3)
  def test_a_run_of_half_items_is_filled_the_same_on_both = assert_run_filled(:half, -300)
  def test_a_run_of_word_items_is_filled_the_same_on_both = assert_run_filled(:word, -70_000)

  # A run of nought, or fewer, writes nothing.
  def test_a_run_of_nothing_fills_nothing
    prog = filled(:byte, from: 3, count: 0, value: 9)

    assert_equal [1] * ITEMS, items_on_console(prog)
    assert_equal [1] * ITEMS, items_on_interpreter(prog)
  end

  # On the console a bad index stays inside the list, the way one list_set's does: a run off
  # the end stops at the end, and one starting before the list writes nothing. The interpreter
  # says so instead, as it does for a list_set.
  def test_a_run_off_the_end_stays_inside_the_list_on_the_console
    assert_equal [1] * 10 + [9] * 3, items_on_console(filled(:byte, from: 10, count: 10, value: 9))
    assert_equal [1] * ITEMS, items_on_console(filled(:byte, from: -2, count: 5, value: 9))
  end

  def test_a_run_off_the_end_is_an_error_on_the_interpreter
    error = assert_raises(Reference::ProgramError) { items_on_interpreter(filled(:byte, from: 10, count: 10, value: 9)) }

    assert_match(/out of range/, error.message)
  end
end

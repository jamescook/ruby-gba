# frozen_string_literal: true

require "test_helper"

# A fill by the console's copying engine reads its colour from one word of memory, and the
# engine is told that word's ADDRESS each time — as a number, built by instructions. How many
# depends on the address's bits: the first address of the quick memory is the one the chip
# builds in a single instruction, and most others take two or three.
#
# The word used to get whatever address was free when the first fill was lowered, so what
# every fill in a game cost was decided by how many variables happened to be named before it.
class TestFillScratchWord < Minitest::Test
  FIRST = RubyGBA::Console::Hardware::IWRAM_START
  A = RubyGBA::IR::Backends::GBA::ASM

  # A game that names a lot of variables before it ever fills anything.
  def program_with_many_variables
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      counters = Array.new(70) { |n| var :"counter_#{n}", n }
      game_loop do
        clear_screen :blue
        fill_rect 10, 10, 20, 20, :red
        counters.first.add! 1
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_the_scratch_word_is_at_the_first_address_however_many_variables_came_before
    backend = GBA.new
    backend.lower(program_with_many_variables)

    assert_equal FIRST, backend.var_addresses.fetch(:_dma_scratch)
    assert_equal 4, A.load_immediate(0, FIRST).bytesize, "which is one instruction to build"
  end

  # ...and the fills still land, and the variables still count, on both backends.
  def test_the_fills_and_the_variables_are_unchanged
    program = program_with_many_variables
    oracle = Reference.new.run(program, frames: 3)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "SCRATCH", maker: "01", built: backend.build_record(program))
    console = assert_emulator_loads_rom(rom, frames: 6, vars: backend.var_addresses)

    assert console.pixel_is?(100, 100, :blue), "the clear"
    assert console.pixel_is?(15, 15, :red), "the rectangle"
    assert_equal 69, console.var(:counter_69)
    assert_equal oracle.screen.pixel(15, 15), console.pixel_gba(15, 15)
  end
end

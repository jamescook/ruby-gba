# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_bit_operations"

# Bit operations on the Advance's cartridge: the programs of
# test/all/vblank/dsl/test_bit_operations.rb run on the console, read back in the emulator and
# held to the same answers, and what the code for them costs.
class TestBitOperationsCartridge < Minitest::Test
  include BitOperationsCases

  Int32 = VBlank::IR::Int32

  def test_reading_one_bit_per_pixel_out_of_a_collision_shape_on_the_console
    expected, game = collision_shape_case
    assert_console_computes(expected, &game)
  end

  def test_a_packed_map_cell_comes_apart_and_goes_back_together_on_the_console
    expected, game = packed_cell_case
    assert_console_computes(expected, &game)
  end

  def test_setting_clearing_and_testing_flags_in_one_word_on_the_console
    expected, game = flags_case
    assert_console_computes(expected, &game)
  end

  def test_a_shift_past_the_end_of_the_number_empties_it_on_the_console
    expected, game = shift_past_end_case
    assert_console_computes(expected, &game)
  end

  def test_a_written_down_count_past_the_end_is_settled_by_the_build_on_the_console
    expected, program = written_down_count_case

    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "BITEDGE", code: "BBTE", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    expected.each { |name, want| assert_equal want, Int32.wrap(v.var(name)), "the console's #{name}" }
  end

  # A number written on the left of a mask (test_a_number_written_in_the_program_can_stand_on_the_left)
  # costs the same either way round, which it would not if the build put both sides through the
  # stack just because the number was written first.
  def test_a_number_on_the_left_costs_what_it_costs_on_the_right
    left = emitted { |value| set! :masked, 0x0F & value }
    right = emitted { |value| set! :masked, value & 0x0F }

    assert_equal right, left, "a mask written on the left emitted more code than the same mask on the right"
  end

  private

  # How many bytes of code one expression came out as. The block is handed a variable
  # to work on, so only the expression differs between two of these.
  def emitted(&shape)
    program = build_program do
      screen :bitmap
      value = var :value, 0x3C
      var :masked, 0
      instance_exec(value, &shape)
      halt
    end
    GBA.new.lower(program).bytesize
  end

  # The real console is where a lowering that took a shortcut shows up. The console hands a
  # variable back as a plain 32 bits, so it is read as a signed number before the two are
  # compared.
  def assert_console_computes(expected, &block)
    program = build_program(&block)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "BITOPS", code: "BBIT", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    expected.each do |name, want|
      assert_equal want, Int32.wrap(v.var(name)), "#{name} on the Advance's cartridge"
    end
  end
end

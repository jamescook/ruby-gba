# frozen_string_literal: true

require "test_helper"

# THE RULES OF THE SAVE MEMORY A PROGRAM SAYS IT HAS, kept by the interpreter.
#
# Battery-backed memory takes any byte anywhere, as often as you like. Flash does not: a write
# can only turn bits off, and the only way to turn them back on is to wipe a whole 4K block,
# which leaves every byte of it 0xFF. A write order that forgets the wipe works on the first
# kind and corrupts saves on the second, so the interpreter refuses it here, where a test sees
# it, rather than leaving it for a player to find.
class TestSaveMemoryRules < Minitest::Test
  B = RubyGBA::IR::Build

  private def run_program(*statements, store: { bytes: {} })
    Reference.new(save: store).run(B.program(*statements, B.halt), frames: 1)
    store[:bytes]
  end

  private def byte_write(at, value) = B.save_write(B.int(at), B.int(value), width: :byte)

  def test_on_flash_a_write_that_turns_a_bit_back_on_is_refused
    error = assert_raises(Reference::ProgramError) do
      run_program(B.save_memory(64), byte_write(0x4000, 0x12), byte_write(0x4000, 0x34))
    end

    assert_match(/0x4000/, error.message)
  end

  def test_on_flash_a_write_that_only_turns_bits_off_is_kept
    assert_equal 0x10, run_program(B.save_memory(64), byte_write(0x4000, 0x12), byte_write(0x4000, 0x10))[0x4000]
  end

  def test_on_flash_a_wiped_block_reads_0xff_and_takes_any_byte_again
    bytes = run_program(B.save_memory(128), byte_write(0x5000, 0x12), byte_write(0x5FFF, 0x00),
                        byte_write(0x6000, 0x00), B.save_erase(B.int(0x5123)), byte_write(0x5000, 0x34))

    assert_equal 0x34, bytes[0x5000]
    assert_equal 0xFF, bytes.fetch(0x5FFF, 0xFF), "the whole block is wiped"
    assert_equal 0x00, bytes[0x6000], "and the next block is not"
  end

  # The power going off stops a wipe as surely as a write: the block keeps what it held.
  def test_a_wipe_after_the_power_went_off_does_not_happen
    store = { bytes: {} }
    program = B.program(B.save_memory(64), byte_write(0x5000, 0x12), B.save_erase(B.int(0x5000)), B.halt)
    Reference.new(save: store).cut_power_after_saving(1).run(program, frames: 1)

    assert_equal 0x12, store[:bytes][0x5000]
  end

  def test_battery_memory_takes_any_byte_and_a_wipe_does_nothing
    bytes = run_program(B.save_memory(32), byte_write(0x1000, 0x12), byte_write(0x1000, 0x34),
                        B.save_erase(B.int(0x1000)))

    assert_equal 0x34, bytes[0x1000]
  end

  def test_a_program_that_names_no_save_memory_has_battery_memory
    assert_equal 0x34, run_program(byte_write(0x1000, 0x12), byte_write(0x1000, 0x34))[0x1000]
  end
end

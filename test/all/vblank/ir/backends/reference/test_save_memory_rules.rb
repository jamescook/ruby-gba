# frozen_string_literal: true

require "test_helper"

# The steps these tests write, kept once for the interpreter's own test of a power cut
# (test/interpreter/vblank/ir/backends/reference/test_save_memory_rules_interpreter.rb).
module SaveMemoryRulesPrograms
  B = VBlank::IR::Build

  private def byte_write(at, value) = B.save_write(B.int(at), B.int(value), width: :byte)
end

# THE RULES OF THE SAVE MEMORY A PROGRAM SAYS IT HAS, kept by the interpreter.
#
# Battery-backed memory takes any byte anywhere, as often as you like. Flash does not: a write
# can only turn bits off, and the only way to turn them back on is to wipe a whole 4K block,
# which leaves every byte of it 0xFF. A write order that forgets the wipe works on the first
# kind and corrupts saves on the second, so the interpreter refuses it here, where a test sees
# it, rather than leaving it for a player to find.
class TestSaveMemoryRules < Minitest::Test
  include SaveMemoryRulesPrograms

  private def run_program(*statements)
    store = SaveImage.new
    game_player(save: store).run(B.program(*statements, B.halt), frames: 1)
    store
  end

  def test_on_flash_a_write_that_turns_a_bit_back_on_is_refused
    error = assert_raises(Reference::ProgramError) do
      run_program(B.save_memory(64), byte_write(0x4000, 0x12), byte_write(0x4000, 0x34))
    end

    assert_match(/0x4000/, error.message)
  end

  def test_a_write_before_a_started_wipe_is_seen_finished_is_refused
    error = assert_raises(Reference::ProgramError) do
      run_program(B.save_memory(64), B.save_erase(B.int(0x5000), wait: false), byte_write(0x6000, 0x12))
    end

    assert_match(/wipe/, error.message)
  end

  # A wipe takes long enough for the power to go off in the middle of it, and then the block
  # is neither what it held nor wiped: the part the chip reached reads 0xFF, the rest is as it
  # was. A cut is counted in steps, a byte written one step and a wipe two, so a cut one step
  # before the wipe lands half way through it.
  def test_a_wipe_the_power_cuts_half_way_leaves_part_of_the_block_wiped
    store = SaveImage.new(kilobytes: 64)
    store.write(0x5000, 0x12, 1)
    store.write(0x5FFF, 0x34, 1)
    store.cut_power_after(1)

    assert_raises(SaveImage::PowerOff) { store.wipe_block(0x5000) }
    assert_equal [0xFF, 0x34], [store.read(0x5000, 1), store.read(0x5FFF, 1)]
  end

  # The console's chip has no byte past its end — a place past it lands back at the start, or
  # nowhere — so a program that writes or reads there is refused, naming the size.
  def test_a_place_past_the_end_of_save_memory_is_refused
    write = assert_raises(Reference::ProgramError) { run_program(B.save_memory(64), byte_write(0x10000, 1)) }
    read = assert_raises(Reference::ProgramError) do
      run_program(B.set(:x, B.save_read(B.int(0x7FFE), width: :word)))
    end

    assert_match(/64K/, write.message)
    assert_match(/32K/, read.message)
  end

  def test_battery_memory_takes_any_byte_and_a_wipe_does_nothing
    store = run_program(B.save_memory(32), byte_write(0x1000, 0x12), byte_write(0x1000, 0x34),
                        B.save_erase(B.int(0x1000)))

    assert_equal 0x34, store.read(0x1000, 1)
  end

  def test_a_program_that_names_no_save_memory_has_battery_memory
    assert_equal 0x34, run_program(byte_write(0x1000, 0x12), byte_write(0x1000, 0x34)).read(0x1000, 1)
  end

  # A cut the run never reached being gone at the next run is the interpreter's alone, since a
  # cut is counted in its steps: test/interpreter/vblank/ir/backends/reference/test_save_memory_rules_interpreter.rb.

  def test_the_interpreter_is_handed_a_save_memory_not_a_hash
    err = assert_raises(ArgumentError) { game_player(save: {}) }
    assert_match(/SaveImage.new/, err.message)
  end

  # A chip is one size for good, so a program that says another is refused.
  def test_a_save_memory_of_another_size_is_refused
    store = SaveImage.new(kilobytes: 64)
    err = assert_raises(ArgumentError) { game_player(save: store).run(B.program(B.halt), frames: 1) }
    assert_match(/64K/, err.message)
  end
end

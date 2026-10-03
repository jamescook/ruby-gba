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

  private def run_program(*statements)
    store = SaveImage.new
    Reference.new(save: store).run(B.program(*statements, B.halt), frames: 1)
    store
  end

  private def byte_write(at, value) = B.save_write(B.int(at), B.int(value), width: :byte)

  def test_on_flash_a_write_that_turns_a_bit_back_on_is_refused
    error = assert_raises(Reference::ProgramError) do
      run_program(B.save_memory(64), byte_write(0x4000, 0x12), byte_write(0x4000, 0x34))
    end

    assert_match(/0x4000/, error.message)
  end

  def test_on_flash_a_write_that_only_turns_bits_off_is_kept
    assert_equal 0x10, run_program(B.save_memory(64), byte_write(0x4000, 0x12), byte_write(0x4000, 0x10)).read(0x4000, 1)
  end

  def test_on_flash_a_wiped_block_reads_0xff_and_takes_any_byte_again
    store = run_program(B.save_memory(128), byte_write(0x5000, 0x12), byte_write(0x5FFF, 0x00),
                        byte_write(0x6000, 0x00), B.save_erase(B.int(0x5123)), byte_write(0x5000, 0x34))

    assert_equal 0x34, store.read(0x5000, 1)
    assert_equal 0xFF, store.read(0x5FFF, 1), "the whole block is wiped"
    assert_equal 0x00, store.read(0x6000, 1), "and the next block is not"
  end

  # A wipe that is only started is still going on until the program sees it finished. The chip
  # says it is busy to the first read of the block, and is finished by the next one.
  def test_a_started_wipe_reads_busy_once_then_0xff
    first = B.save_read(B.int(0x5000), width: :byte)
    program = B.program(B.save_memory(64), byte_write(0x5000, 0x12), B.save_erase(B.int(0x5000), wait: false),
                        B.set(:busy, first), B.set(:done, first), B.halt)
    run = Reference.new(save: SaveImage.new).run(program, frames: 1)

    refute_equal 0xFF, run[:busy]
    assert_equal 0xFF, run[:done]
  end

  def test_a_write_before_a_started_wipe_is_seen_finished_is_refused
    error = assert_raises(Reference::ProgramError) do
      run_program(B.save_memory(64), B.save_erase(B.int(0x5000), wait: false), byte_write(0x6000, 0x12))
    end

    assert_match(/wipe/, error.message)
  end

  # The power going off stops a wipe as surely as a write: the block keeps what it held.
  def test_a_wipe_after_the_power_went_off_does_not_happen
    store = SaveImage.new.cut_power_after(1)
    program = B.program(B.save_memory(64), byte_write(0x5000, 0x12), B.save_erase(B.int(0x5000)), B.halt)
    Reference.new(save: store).run(program, frames: 1)

    assert_equal 0x12, store.read(0x5000, 1)
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

  # A cut is for one run: one the run never reached is not waiting for the next run, nor in a copy.
  def test_a_cut_the_run_never_reached_is_gone_at_the_next_run
    store = SaveImage.new.cut_power_after(100)
    copy = store.dup
    Reference.new(save: store).run(B.program(byte_write(0x1000, 0x12), B.halt), frames: 1)
    Reference.new(save: store).run(B.program(*(0...200).map { |i| byte_write(0x1000 + i, 0x34) }, B.halt), frames: 1)
    Reference.new(save: copy).run(B.program(*(0...200).map { |i| byte_write(0x1000 + i, 0x56) }, B.halt), frames: 1)

    assert_equal 0x34, store.read(0x1000 + 199, 1)
    assert_equal 0x56, copy.read(0x1000 + 199, 1)
  end

  def test_the_interpreter_is_handed_a_save_memory_not_a_hash
    err = assert_raises(ArgumentError) { Reference.new(save: {}) }
    assert_match(/SaveImage.new/, err.message)
  end

  # A chip is one size for good, so a program that says another is refused.
  def test_a_save_memory_of_another_size_is_refused
    store = SaveImage.new(kilobytes: 64)
    err = assert_raises(ArgumentError) { Reference.new(save: store).run(B.program(B.halt), frames: 1) }
    assert_match(/64K/, err.message)
  end
end

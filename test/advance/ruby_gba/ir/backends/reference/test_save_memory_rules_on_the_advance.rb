# frozen_string_literal: true

require "test_helper"

# THE TESTS OF ruby_gba/ir/backends/reference/test_save_memory_rules.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# THE RULES OF THE SAVE MEMORY A PROGRAM SAYS IT HAS, kept by the interpreter.
#
# Battery-backed memory takes any byte anywhere, as often as you like. Flash does not: a write
# can only turn bits off, and the only way to turn them back on is to wipe a whole 4K block,
# which leaves every byte of it 0xFF. A write order that forgets the wipe works on the first
# kind and corrupts saves on the second, so the interpreter refuses it here, where a test sees
# it, rather than leaving it for a player to find.
class TestSaveMemoryRulesOnTheAdvance < Minitest::Test
  B = RubyGBA::IR::Build

  private def run_program(*statements)
    store = SaveImage.new
    game_player(save: store).run(B.program(*statements, B.halt), frames: 1)
    store
  end

  private def byte_write(at, value) = B.save_write(B.int(at), B.int(value), width: :byte)

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
    run = game_player(save: SaveImage.new).run(program, frames: 1)

    refute_equal 0xFF, run[:busy]
    assert_equal 0xFF, run[:done]
  end

  # The power going off stops a wipe as surely as a write: the block keeps what it held.
  def test_a_wipe_after_the_power_went_off_does_not_happen
    store = SaveImage.new.cut_power_after(1)
    program = B.program(B.save_memory(64), byte_write(0x5000, 0x12), B.save_erase(B.int(0x5000)), B.halt)
    game_player(save: store).run(program, frames: 1)

    assert_equal 0x12, store.read(0x5000, 1)
  end

end

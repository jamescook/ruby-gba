# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/backends/reference/test_save_memory_rules"

# A power cut in the save memory, counted in the interpreter's steps, which only the interpreter
# has. The rules of the save memory every run keeps are in
# test/all/vblank/ir/backends/reference/test_save_memory_rules.rb.
class TestSaveMemoryRulesInterpreter < Minitest::Test
  include SaveMemoryRulesPrograms

  # A cut is for one run: one the run never reached is not waiting for the next run, nor in a copy.
  def test_a_cut_the_run_never_reached_is_gone_at_the_next_run
    store = SaveImage.new.cut_power_after(100)
    copy = store.dup
    game_player(save: store).run(B.program(byte_write(0x1000, 0x12), B.halt), frames: 1)
    game_player(save: store).run(B.program(*(0...200).map { |i| byte_write(0x1000 + i, 0x34) }, B.halt), frames: 1)
    game_player(save: copy).run(B.program(*(0...200).map { |i| byte_write(0x1000 + i, 0x56) }, B.halt), frames: 1)

    assert_equal 0x34, store.read(0x1000 + 199, 1)
    assert_equal 0x56, copy.read(0x1000 + 199, 1)
  end
end

# frozen_string_literal: true

require "test_helper"

# A `save_var` ON 64K OR 128K OF SAVE MEMORY, which is flash: the save_vars are kept in a
# record of their own that saves itself a pass after one of them changes, rather than written
# in place as they are on 32K. The record on the Advance's cartridge, saved and read back in the
# emulator, is in test/lowering/gba/vblank/builder/test_save_var_record_cartridge.rb.
class TestSaveVarRecord < Minitest::Test
  def test_a_save_var_on_flash_in_a_game_with_no_game_loop_is_refused
    message = assert_raises(ArgumentError) do
      VBlank.build("FLASHVAR", console: :gba, out: nil, err: nil, save_memory: 64) do
        screen :bitmap
        save_var :best, 0
        halt
      end
    end.message

    assert_match(/no game_loop/, message)
    assert_match(/never saved/, message)
  end
end

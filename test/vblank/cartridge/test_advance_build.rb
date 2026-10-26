# frozen_string_literal: true

require "test_helper"

# THE ADVANCE'S OWN SETTINGS (Cartridge::AdvanceBuild::SETTINGS): a value its build cannot use is
# refused where the game is named, before anything is read or built.
class TestAdvanceBuild < Minitest::Test
  # How much of the quick memory the game's stack is given: a number of bytes the stack can hold
  # whole numbers in, from the least the console's own routines need to half the quick memory.
  def test_stack_room_the_stack_cannot_have_is_refused
    [1001, 32, 32_768, "lots", 1024.0].each do |wrong|
      error = assert_raises(ArgumentError) { VBlank.game("BADSTACK", consoles: %i[gba], stack_room: wrong) { halt } }

      assert_match(/stack_room: #{Regexp.escape(wrong.inspect)}/, error.message)
      assert_match(/multiple of 4/, error.message)
    end
  end

  def test_stack_room_a_stack_can_have_is_taken
    [64, 512, 16_384].each do |room|
      assert_equal room, VBlank.game("GOODSTACK", consoles: %i[gba], stack_room: room) { halt }.options.stack_room
    end
  end

  # What the game said, and the Advance's own choice for what it did not, is what the cartridge
  # records it was built with.
  def test_a_cartridge_records_the_advance_settings_it_was_built_with
    game = VBlank.game("BOTHSET", consoles: %i[gba gbc], stack_room: 512, fast_code: false) { halt }

    assert_equal({ fast_cartridge: true, fast_code: false, stack_room: 512 },
                 game.build_rom(out: nil, err: nil, profile: false, console: :gba).build_options)
  end
end

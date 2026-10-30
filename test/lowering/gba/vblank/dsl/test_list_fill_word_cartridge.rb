# frozen_string_literal: true

require "test_helper"
require "stringio"
require "all/vblank/dsl/test_list_fill_word"

# A LIST FILLED IN ONE STEP ON THE ADVANCE'S CARTRIDGE: the items read back in the emulator, and
# what clearing a box costs a frame. The same fills on every run are in
# test/all/vblank/dsl/test_list_fill_word.rb.
class TestListFillWordCartridge < Minitest::Test
  include ListFillWordGames

  private def on_console(game)
    rom = VBlank.build("LISTFILL", console: :gba, out: StringIO.new, err: StringIO.new, profile: false, &game)
    v = assert_emulator_loads_rom(rom, frames: 4, vars: rom.var_addresses)
    READINGS.map { |name| v.var(name) }
  end

  def test_the_whole_list_takes_a_value_worked_out_as_the_game_runs
    game = filling { |canvas, shade| canvas.fill shade }

    assert_equal [0x77, 0x77, 0x77, 0x77, 0x77, SIZE], on_console(game)
  end

  # A byte that reads below nothing goes in as the console's byte does: 0xFF is -1.
  def test_a_run_from_a_worked_out_start_sets_only_those_items
    game = filling { |canvas, _shade, start| canvas.fill 0xFF, from: start, count: start - 2 }

    assert_equal [0, 0, -1, 0, 0, SIZE], on_console(game)
  end

  # WHAT IT IS FOR: a dialogue box's 3,328 bytes cleared on the frame it opens. One at a time
  # from the cartridge, that is most of a frame; filled, a small part of one.
  def test_clearing_a_box_every_frame_takes_a_small_part_of_it
    rom = VBlank.build("CLEARBOX", console: :gba, out: StringIO.new, err: StringIO.new, profile: false, fast_code: false,
                                    &filling { |canvas, shade| canvas.fill shade })
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)

    assert_operator result.idle_share, :>, 0.95, "the clear left #{result.idle_share} of the frame"
  end
end

# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_save_data_on_the_advance"

# The power cut off part way through a save on flash, which only the interpreter's save memory
# can do (SaveImage#cut_power_after). The game, and why a wipe on flash is safe to cut, is
# `one_file_on_flash` in test/console/gba/vblank/builder/test_save_data_on_the_advance.rb.
class TestSaveDataOnTheAdvanceInterpreter < Minitest::Test
  include SaveDataOnTheAdvanceGames

  def test_a_save_on_flash_cut_off_at_any_point_keeps_the_last_good_one
    program = one_file_on_flash
    before = SaveImage.new(kilobytes: 64)
    game_player(save: before).input_each_frame { |f| { 2 => [:a], 60 => [:b] }.fetch(f, []) }.run(program, frames: 120)
    assert_equal 9, game_player(save: before.dup).run(program, frames: 2)[:hearts], "two saves went in"

    found = (0..80).map do |cut|
      store = before.dup
      game_player(save: store.cut_power_after(cut)).input_each_frame { |f| f == 2 ? [:l] : [] }
               .run(program, frames: 120)
      store.restore_power

      game_player(save: store).run(program, frames: 2)[:hearts].tap do |hearts|
        assert_includes [9, 11], hearts, "cut after #{cut} steps"
      end
    end
    assert_equal [9, 11], found.uniq.sort, "the cuts reach from before the save to after it"
  end
end

# frozen_string_literal: true

require "test_helper"

# HOW MANY TIMES ROUND THE GAME LOOP THE CONSOLE GOT.
#
# Not the frame count, and the difference is the whole point: the console runs the loop once
# per frame it has TIME for, so a game whose pass does not fit in a frame plays less game per
# frame than one that does. Anything lining a console run up against a run somewhere else —
# the interpreter, an earlier build — has to line up on passes, and the whole-screen
# cross-backend comparison is built on exactly this.
#
# It is counted by watching for the game loop's own first instruction while the cartridge
# runs. The alternative, which this replaced, was adding a variable and an instruction to the
# loop and reading that back — which measures a cartridge nobody ships, and one extra
# instruction can tip a routine out of the console's quick memory and change the timing being
# measured.
class TestVerifierPasses < Minitest::Test
  # A loop that counts its own passes, so the emulator's count has something exact to be
  # checked against. The counter is the last thing in the body, so it says how many passes
  # FINISHED — which is what #passes reports.
  def self_counting_rom
    RubyGBA.build("PASSES", validate: false) do
      screen :bitmap
      clear_screen :black
      passes = var :passes, 0
      game_loop { passes.add! 1 }
    end
  end

  # A pass far too big for one frame: the console gets fewer passes than the frames that ran,
  # which is the situation the count exists for.
  def overrunning_rom
    RubyGBA.build("HEAVY", validate: false) do
      screen :bitmap
      passes = var :passes, 0
      game_loop do
        repeat(40) { clear_screen :blue }
        passes.add! 1
      end
    end
  end

  def test_the_count_agrees_with_a_counter_the_program_keeps_itself
    rom = self_counting_rom
    v = assert_emulator_loads_rom(rom, frames: 10, vars: rom.var_addresses, count_passes: true)

    assert_equal v.var(:passes), v.passes,
                 "the emulator's count and the program's own must be the same number"
  end

  def test_a_game_that_keeps_up_makes_a_pass_for_nearly_every_frame
    rom = self_counting_rom
    v = assert_emulator_loads_rom(rom, frames: 10, vars: rom.var_addresses, count_passes: true)

    assert_operator v.passes, :>=, 8, "10 frames, minus the console's own boot"
    assert_operator v.passes, :<=, 10, "it cannot go round more often than there were frames"
  end

  def test_a_game_too_heavy_for_its_frame_makes_fewer_passes_than_frames
    rom = overrunning_rom
    v = assert_emulator_loads_rom(rom, frames: 20, vars: rom.var_addresses, count_passes: true)

    assert_equal v.var(:passes), v.passes, "still exact when the game is over budget"
    assert_operator v.passes, :<=, 5, "40 whole-screen fills take several frames each pass"
  end

  # A loop the build left in the cartridge is a different shape — written out in place rather
  # than called — so a different instruction of it is watched. Both shapes have to give the
  # same answer, and this is the one whose first instruction cannot be used (it is the
  # instruction that asks the console to sleep, which the console's own startup can enter
  # twice).
  def test_a_loop_left_in_the_cartridge_is_counted_the_same
    rom = RubyGBA.build("SLOWMEM", validate: false, fast_code: false) do
      screen :bitmap
      clear_screen :black
      passes = var :passes, 0
      game_loop { passes.add! 1 }
    end
    v = assert_emulator_loads_rom(rom, frames: 10, vars: rom.var_addresses, count_passes: true)

    assert_equal v.var(:passes), v.passes
    assert_operator v.passes, :>=, 8
  end

  def test_a_heavy_loop_left_in_the_cartridge_is_counted_the_same
    rom = RubyGBA.build("SLOWHEAVY", validate: false, fast_code: false) do
      screen :bitmap
      passes = var :passes, 0
      game_loop do
        repeat(40) { clear_screen :blue }
        passes.add! 1
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 20, vars: rom.var_addresses, count_passes: true)

    assert_equal v.var(:passes), v.passes
    assert_operator v.passes, :<=, 5
  end

  # A game that places its own wait for the screen puts a different instruction first again.
  def test_a_game_that_waits_for_the_screen_itself_is_counted_the_same
    rom = RubyGBA.build("MANUAL", validate: false, frame_sync: :manual) do
      screen :bitmap
      clear_screen :black
      passes = var :passes, 0
      game_loop do
        wait_vblank
        passes.add! 1
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 12, vars: rom.var_addresses, count_passes: true)

    assert_equal v.var(:passes), v.passes
    assert_operator v.passes, :>=, 10
  end

  def test_a_program_with_no_game_loop_has_no_passes
    rom = RubyGBA.build("NOLOOP", validate: false) do
      screen :bitmap
      clear_screen :red
      halt
    end
    v = assert_emulator_loads_rom(rom, frames: 4, count_passes: true)

    assert_nil v.passes, "no loop is a different answer from none of its passes finishing"
  end

  def test_asking_for_passes_without_counting_them_says_so
    rom = self_counting_rom
    v = assert_emulator_loads_rom(rom, frames: 4)

    error = assert_raises(ArgumentError) { v.passes }
    assert_match(/count_passes/, error.message)
  end
end

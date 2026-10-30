# frozen_string_literal: true

require "test_helper"

# A CARTRIDGE BUILT TO BE CHECKED AGAINST THE INTERPRETER (GBA.new(checked: true)) keeps how its run
# stands where a reader of it looks (GBA::Runtime::Frame, by the names every console's reader asks
# for): how many passes have ended, which one the screen shows, whether the game waits, the frames
# each pass took, how it stands and what went wrong. Read back here in the emulator, a frame at a
# time. A cartridge for a player keeps none of it, and is the bytes it always was (rake emitted:check).
class TestCheckedBuild < Minitest::Test
  Frame = VBlank::IR::Backends::GBA::Runtime::Frame

  private def checked_cartridge(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval(&block)
    b.finalize_program
    VBlank::Cartridge::AdvanceBuild.checked_cartridge_for(b.program, title: "CHECKED")
  end

  # Plays +rom+ for +frames+ frames, then yields the core and where each name is kept.
  private def play(rom, frames)
    require_emulator!
    VBlank::Diagnostics::Emulator.with_cartridge(rom, file_name: "checked.gba") do |core|
      frames.times { core.run_frame }
      yield core, rom.built.runtime
    end
  end

  private def counting_game
    checked_cartridge do
      screen :bitmap
      count = var :count, 0
      game_loop { count.add! 1 }
    end
  end

  def test_the_passes_ended_count_up_a_frame_at_a_time_and_the_screen_shows_the_last
    play(counting_game, 20) do |core, at|
      passes = core.bus_read32(at.fetch(Frame::PASSES))
      assert_operator passes, :>=, 15
      assert_includes [passes, passes - 1], core.bus_read32(at.fetch(Frame::SHOWN))
      assert_equal Frame::RUNNING, core.bus_read32(at.fetch(Frame::STATE))
      assert_in_delta 20, core.bus_read32(at.fetch(Frame::FRAMES)), 2
      assert_equal 1, core.bus_read8(at.fetch(Frame::STEPS) + ((passes - 1) % Frame::STEPS_KEPT)), "a pass that keeps up takes one frame"
    end
  end

  def test_a_held_pass_is_the_last_the_game_plays
    play(counting_game, 10) do |core, at|
      core.bus_write32(at.fetch(Frame::HOLD), 1)
      2.times { core.run_frame }
      held = core.bus_read32(at.fetch(Frame::PASSES))
      10.times { core.run_frame }

      assert_equal held, core.bus_read32(at.fetch(Frame::PASSES)), "no pass after the held one"
      assert_equal held, core.bus_read32(at.fetch(Frame::SHOWN))
      assert_equal 1, core.bus_read32(at.fetch(Frame::WAITING))
    end
  end

  # A list of three read at five, on the game's third pass, stops it as the interpreter stops it:
  # the number for an index out of range, the list's place, the index and the list's length.
  def test_a_list_read_past_its_end_stops_the_game_and_keeps_what_went_wrong
    rom = checked_cartridge do
      screen :bitmap
      items = list :items, capacity: 8
      3.times { |n| items.push n }
      count = var :count, 0
      seen = var :seen, 0
      game_loop do
        count.add! 1
        (count == 3).then { seen.set! items[count + 2] }
      end
    end
    play(rom, 12) do |core, at|
      fault = at.fetch(Frame::FAULT)
      assert_equal Frame::WENT_WRONG, core.bus_read32(at.fetch(Frame::STATE))
      assert_equal [Frame::INDEX_OUT_OF_RANGE, 5, 3],
                   [core.bus_read32(fault), core.bus_read32(fault + 8), core.bus_read32(fault + 12)]
      assert_predicate core.bus_read32(fault + 4), :positive?, "where the list is kept"
      assert_equal Frame::END_SHOWN, core.bus_read32(at.fetch(Frame::SHOWN))
    end
  end

  def test_a_game_that_halts_says_so_and_shows_its_end
    rom = checked_cartridge do
      screen :bitmap
      clear_screen :red
      halt
    end
    play(rom, 6) do |core, at|
      assert_equal Frame::HALTED, core.bus_read32(at.fetch(Frame::STATE))
      assert_equal Frame::END_SHOWN, core.bus_read32(at.fetch(Frame::SHOWN))
    end
  end
end

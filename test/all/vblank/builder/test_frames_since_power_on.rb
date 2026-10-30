# frozen_string_literal: true

require "test_helper"

# `frames_since_power_on`: how many frames the screen has shown since the power came on, setting
# up included — so a screen held until it reaches a number ends on that frame however long the
# game took to set up.
class TestFramesSincePowerOn < Minitest::Test
  # A bitmap room that spins +busy+ times before its loop, then notes what the reading was on its
  # first pass and what it is on every pass.
  private def counting_game(busy = 0)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      spin = var :spin, 0
      passes = var :passes, 0
      first = var :first, -1
      now = var :now, -1
      repeat(busy) { spin.add! 1 } if busy.positive?
      game_loop do
        (passes == 0).then { first.set! frames_since_power_on }
        now.set! frames_since_power_on
        passes.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  def test_each_pass_of_a_game_that_keeps_up_reads_one_more_frame
    seen = []
    run = game_player
    run.each_vblank { seen << run[:now] }
    run.run(counting_game, frames: 5)

    assert_equal(-1, seen.first) # read before the first pass
    # The first pass reads the frames setting up took, one or more; each after it one more.
    assert_operator seen[1], :>=, 1
    assert_equal (seen[1]..(seen[1] + 3)).to_a, seen.drop(1)
  end

  # The interpreter has no clock, so a test says how long a pass took; a pass worth three frames
  # moves the reading on by three, as it does on the console. (What it says for the first frame
  # is what setting up took, which here is one.)
  def test_a_pass_that_takes_three_frames_reads_three_more
    run = Reference.new.frames_each_pass { |frame| frame == 1 ? 1 : 3 }.run(counting_game, frames: 4)

    assert_equal 1, run[:first], "the first pass comes after the first frame"
    assert_equal 1 + (3 * 3), run[:now], "and each pass after it took three"
  end

  # A console whose screen is off while it sets up says how many frames that took, and the
  # reading counts them at the first frame — nothing else moves on for them.
  def test_frames_set_up_with_the_screen_off_are_counted_at_the_first_frame
    run = Reference.new.frames_setting_up(6).run(counting_game, frames: 3)

    assert_equal 7, run[:first], "six frames setting up, then the first frame shown"
    assert_equal 7 + 2, run[:now], "and each pass after it one more"
    assert_equal 3, run[:passes]
  end

  # THE ONE THAT MATTERS. On the console, setting up takes frames, and the reading counts them:
  # the first pass's change is first seen on frame F, so it ran after F - 1 frames had been
  # shown, and that is what it read. Spinning before the loop makes setting up take several.
  private def first_pass_on_the_console(busy)
    gba = GBA.new
    rom = ROM.assemble(gba.lower(counting_game(busy)), title: "POWERON")
    v = assert_emulator_loads_rom(rom, frames: 1, vars: gba.var_addresses)
    frame = 1
    until v.var(:passes).positive?
      flunk "no pass ran in 20 frames" if frame == 20
      v.step
      frame += 1
    end
    [frame, v.var(:first)]
  end

  def test_the_console_counts_the_frames_spent_setting_up
    quick_frame, quick = first_pass_on_the_console(0)
    slow_frame, slow = first_pass_on_the_console(30_000)

    assert_equal quick_frame - 1, quick, "a game that sets up at once reads the frames before its first pass"
    assert_operator slow_frame, :>, quick_frame, "spinning first should make setting up take longer"
    assert_equal slow_frame - 1, slow, "and the frames spent setting up are counted"
  end
end

# frozen_string_literal: true

require "test_helper"

require "stringio"

# WHAT THE AUTHOR INSISTED ON, TAKING THE ROOM OF WHAT RUNS EVERY FRAME. The routine that answers
# the display runs on every frame of every screen and plays the music and the sound effects. What
# a game marks `fast: true` goes in the console's quick memory before it, so a routine insisted on
# for a moment's sake can leave it in the cartridge — and nothing showed that until a test played
# the frames that then ran late. The build says so, naming what was insisted on.
class TestIRGuardrailInterruptFromCartridge < Minitest::Test
  # How many additions the insisted routine holds: enough to leave the interrupt's routine a
  # little short of room, but not so many that the insisted routine does not fit itself.
  CROWDING = 1640

  private def build_warnings(insisted:)
    err = StringIO.new
    VBlank.build("CROWDED", console: :gba, out: StringIO.new, err: err, profile: false) do
      screen :bitmap
      enable_sound
      song(:tune) { voice(1) { note :C4, :quarter } }
      total = var :total, 0
      ticks = var :ticks, 0
      # A timer twice a frame keeps the interrupt's routine wanted in the quick memory.
      timer(:beat, per_second: 120).on_tick { ticks.add! 1 }
      func(:heavy, fast: insisted) { CROWDING.times { |n| total.add! n } }
      play_song :tune
      game_loop { call :heavy }
    end
    err.string
  end

  def test_an_insisted_routine_that_leaves_out_the_interrupt_is_named
    warnings = build_warnings(insisted: true)

    assert_match(/answers the display/, warnings)
    assert_match(/every frame/, warnings)
    assert_match(/func :heavy/, warnings, "the warning names what was insisted on")
    assert_match(/fast: true/, warnings)
  end

  # Left to choose, the build would keep the interrupt's routine before the heavy one, so there
  # is nothing to say.
  def test_a_build_that_chose_for_itself_says_nothing
    refute_match(/answers the display/, build_warnings(insisted: nil))
  end

  # The game loop's own body takes the room, and a small routine the game insisted on is not
  # what left the interrupt's routine out, so it is not blamed.
  def test_a_small_insisted_routine_that_took_no_part_is_not_named
    err = StringIO.new
    rom = VBlank.build("CROWDED", console: :gba, out: StringIO.new, err: err, profile: false) do
      screen :bitmap
      enable_sound
      song(:tune) { voice(1) { note :C4, :quarter } }
      total = var :total, 0
      ticks = var :ticks, 0
      timer(:beat, per_second: 120).on_tick { ticks.add! 1 }
      func(:tiny, fast: true) { total.add! 1 }
      play_song :tune
      game_loop do
        call :tiny
        CROWDING.times { |n| total.add! n }
      end
    end

    assert(rom.built.placement.passed_over.any? { |o| o.name == GBA::Placement::IRQ_ROUTINE },
           "the interrupt's routine is left out, by the loop")
    refute_match(/answers the display/, err.string)
  end
end

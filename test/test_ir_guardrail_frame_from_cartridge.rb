# frozen_string_literal: true

require "test_helper"
require "stringio"

# The guardrail for a game loop whose body did not fit in the console's quick memory
# (lib/ruby_gba/ir/guardrails/frame_from_cartridge.rb). The loop is where the frame's time
# goes, so leaving it in the cartridge slows the whole game by the factor the quick memory is
# worth — and nothing about the symptom points at the cause, because the cause is the SIZE
# of code in the loop, not the work it does.
class TestFrameFromCartridgeGuardrail < Minitest::Test
  # A loop with a large piece of code in it that seldom runs. +cold_in_a_func+ moves that code
  # into a routine of its own, marked so the chooser leaves it in the cartridge — the fix the
  # warning names.
  def game(cold_in_a_func:)
    err = StringIO.new
    rom = RubyGBA.build("COLD", code: "ZCLD", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      spin = var :spin, 0
      cold = lambda { 4000.times { spin.add 1 } }
      func(:thinking, fast: false) { cold.call } if cold_in_a_func
      game_loop do
        fill_rect 0, 0, 40, 8, :green
        if cold_in_a_func
          (spin == 1).then { call :thinking }
        else
          (spin == 1).then { cold.call }
        end
      end
    end
    [rom, err.string]
  end

  # THE POINT. The loop's body did not fit, so the build says so, in words about the fix
  # rather than about the hardware.
  def test_a_loop_too_big_to_fit_is_told_so_and_told_the_fix
    rom, warnings = game(cold_in_a_func: false)

    refute rom.built.fast_frame?, "the premise: the loop's body was left in the cartridge"
    assert_match(/game loop's body did not fit/, warnings)
    assert_match(/runs from the cartridge/, warnings)
    assert_match(/mark it `fast: false`/, warnings, "the fix is one word, and it is said")
    assert_match(/needs [\d.]+K, and [\d.]+K was free/, warnings, "the numbers an author acts on")
    refute_match(/IWRAM/, warnings, "no hardware name")
  end

  # ...and the fix works: with the cold code in a routine of its own the loop fits, is kept,
  # and nothing is said.
  def test_with_the_cold_code_in_its_own_routine_the_loop_fits_and_nothing_is_said
    rom, warnings = game(cold_in_a_func: true)

    assert rom.built.fast_frame?, "the loop's body is kept in the quick memory"
    refute_match(/did not fit/, warnings)
  end

  # The build report says the same thing about the same routine, by the name a person has for it.
  def test_the_report_names_the_game_loop_rather_than_its_internal_name
    rom, = game(cold_in_a_func: false)
    io = StringIO.new
    RubyGBA::BuildReport.render(rom, out: io)

    assert_match(/the game loop did not fit/, io.string)
    refute_match(/__frame/, io.string)
  end
end

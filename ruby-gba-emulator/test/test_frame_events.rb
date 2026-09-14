# frozen_string_literal: true

require_relative "test_helper"

# WHAT HAPPENED WHILE THAT FRAME RAN.
#
# The binding's contract has been "run a frame, then ask questions", so everything about
# WHEN something happened had to be reconstructed afterwards — and some of it could not be
# reconstructed at all, so the framework resorted to adding a counter to the cartridge and
# measuring that instead. The core tells us these things itself; it just has to be asked.
class TestFrameEvents < Minitest::Test
  include RubyGBAEmulatorTestSupport

  # A game loop reads the pad once a pass, so this is how many passes the game managed —
  # the number the cross-backend test currently gets by adding a counter to the program.
  def test_a_probe_says_how_many_passes_the_game_managed
    path = build_rom("PASSES", code: "TPAS") do
      screen :bitmap
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        held(:right).then { tick.add! 1 }
      end
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(8)

    assert_operator probe.passes, :>, 0, "the game ran, so it read the pad"
    assert_operator probe.passes, :<=, 8, "it cannot have passed more often than there were frames"
  end

  # A cartridge that never reads the pad has no passes to report, and saying so is better
  # than reporting a number that means something else.
  def test_a_game_that_never_reads_the_pad_reports_no_passes
    path = build_rom("NOPAD", code: "TNOP") do
      screen :bitmap
      game_loop { clear_screen :blue }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(8)

    assert_equal 0, probe.passes
  end

  # What the emulator itself said while the frame ran. mGBA reports a bad read or an
  # unimplemented register as a log line; the binding has been discarding every one of them,
  # so a cartridge doing something the console would object to fails a test silently.
  def test_a_probe_keeps_what_the_emulator_said
    path = build_rom("QUIET", code: "TQUI") do
      screen :bitmap
      game_loop { clear_screen :blue }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)

    assert probe.respond_to?(:complaints), "a probe can say what the emulator complained about"
    assert_kind_of Array, probe.complaints
  end
end

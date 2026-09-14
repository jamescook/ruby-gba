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

  def test_a_probe_says_how_often_the_game_asked_for_buttons
    path = build_rom("PADREAD", code: "TPAD") do
      screen :bitmap
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        held(:right).then { tick.add! 1 }
      end
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(8)

    assert_operator probe.pad_reads, :>, 0, "the game ran, and it reads the pad every pass"
    assert_operator probe.pad_reads, :<=, 8, "it cannot have asked more often than there were frames"
  end

  # The trap this name exists to avoid: a game loop that never asks for input reads the pad
  # never, however many times it goes round. So this counts the asking, and a test wanting
  # passes has to count something else.
  def test_a_game_that_never_asks_for_buttons_reads_the_pad_never
    path = build_rom("NOPAD", code: "TNOP") do
      screen :bitmap
      game_loop { clear_screen :blue }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(8)

    assert_equal 0, probe.pad_reads
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

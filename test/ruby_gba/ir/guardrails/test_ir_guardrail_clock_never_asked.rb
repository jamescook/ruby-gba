# frozen_string_literal: true

require "test_helper"

require "stringio"

# A game that shows the time and never asks whether there is a clock. Most emulators give a
# cartridge no clock unless they are told to, and a clock whose battery ran out was never set:
# either way every reading is 0, and the game shows zeros where the player expects the time. The
# build warns, naming the line that reads it, and builds all the same.
class TestIRGuardrailClockNeverAsked < Minitest::Test
  private def build_warnings(&)
    err = StringIO.new
    RubyGBA.build("CLOCK", out: StringIO.new, err: err, &)
    err.string
  end

  def test_reading_the_time_without_asking_warns_and_names_the_line
    warnings = build_warnings do
      screen :bitmap
      hour = var :hour, 0
      game_loop { hour.set! clock.hour }
    end

    assert_match(/clock\.present\?/, warnings)
    assert_match(/clock\.set\?/, warnings)
    assert_match(/every reading is 0/, warnings, "the warning says what the game shows")
    assert_match(/test_ir_guardrail_clock_never_asked\.rb:\d+/, warnings)
  end

  def test_a_game_that_asks_is_not_warned
    warnings = build_warnings do
      screen :bitmap
      hour = var :hour, 0
      game_loop do
        now = clock
        (now.present? & now.set?).then { hour.set! now.hour }
      end
    end

    refute_match(/clock/, warnings)
  end

  # A game that sets the clock reads numbers the framework keeps, and the framework's own
  # routines read every reading and both questions: none of that counts as the game asking.
  def test_a_game_that_sets_the_clock_and_never_asks_is_warned
    warnings = build_warnings do
      screen :bitmap
      hour = var :hour, 0
      game_loop do
        now = clock
        pressed(:a).then { now.set!(year: 2030, month: 1, day: 1, hour: 9, minute: 0, second: 0) }
        hour.set! now.hour
      end
    end

    assert_match(/clock\.set\?/, warnings)
    assert_match(/test_ir_guardrail_clock_never_asked\.rb:\d+/, warnings)
  end

  def test_a_game_that_sets_the_clock_and_asks_is_not_warned
    warnings = build_warnings do
      screen :bitmap
      hour = var :hour, 0
      game_loop do
        now = clock
        pressed(:a).then { now.set!(year: 2030, month: 1, day: 1, hour: 9, minute: 0, second: 0) }
        now.set?.then { hour.set! now.hour }
      end
    end

    refute_match(/clock/, warnings)
  end
end

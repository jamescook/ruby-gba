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
    RubyGBA.build("CLOCK", console: :gba, out: StringIO.new, err: err, &)
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
end

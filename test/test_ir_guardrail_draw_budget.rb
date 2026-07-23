# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The cost-driven render-budget guardrail: warn (never error) when a game's steady
# per-frame drawing is more than the console can finish before the screen refreshes
# — the overrun that tears the picture. Advisory: the build still produces a ROM.
class TestDrawBudgetGuardrail < Minitest::Test
  Builder = RubyGBA::Builder
  Check = RubyGBA::IR::Guardrails::Checks::DrawBudget

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def test_warns_when_steady_frame_work_exceeds_the_budget
    prog = program do
      display :bitmap
      game_loop do
        wait_vblank
        repeat(100) { |_i| clear_screen :black } # ~3.8M write-units, far over budget
      end
    end
    findings = Check.new.detect(prog)
    assert_equal 1, findings.length
    assert findings.first.warning?, "the render budget is advisory, not a hard error"
    assert_match(/tear/, findings.first.message)
  end

  def test_quiet_when_a_frame_fits
    prog = program do
      display :bitmap
      game_loop do
        wait_vblank
        draw_rect_at 0, 0, 8, 8, :green
      end
    end
    assert_empty Check.new.detect(prog)
  end

  def test_quiet_for_a_static_program
    prog = program do
      display :bitmap
      fill_rect 0, 0, 100, 100, :red # heavy, but drawn once
      halt
    end
    assert_empty Check.new.detect(prog), "a one-shot draw has no per-frame tear risk"
  end

  # It fires during a real build — printed to err — without stopping the ROM.
  def test_build_prints_the_warning_but_still_produces_a_rom
    err = StringIO.new
    rom = RubyGBA.build("HEAVY", code: "BHVY", maker: "01", err: err) do
      display :bitmap
      game_loop do
        wait_vblank
        repeat(100) { |_i| clear_screen :black }
      end
    end
    assert_operator rom.size, :>, 0
    assert_match(/tear/, err.string)
  end
end

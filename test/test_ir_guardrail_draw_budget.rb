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
  Build = RubyGBA::IR::Build

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A loop that clears the whole screen +n+ times a frame, single- or double-
  # buffered — built straight from the IR to set the buffered flag.
  def loop_of_clears(n, buffered:)
    Build.program(
      Build.screen(:bitmap, buffered: buffered),
      Build.loop_(Build.wait_vblank, *Array.new(n) { Build.clear_screen(:black) }),
    )
  end

  def test_warns_when_steady_frame_work_exceeds_the_budget
    prog = program do
      screen :bitmap
      game_loop do
        wait_vblank
        repeat(100) { |_i| clear_screen :black } # 100 whole-screen clears a frame, far over the ~68-scanline budget
      end
    end
    findings = Check.new.detect(prog)
    assert_equal 1, findings.length
    assert findings.first.warning?, "the render budget is advisory, not a hard error"
    assert_match(/tear/, findings.first.message)
  end

  def test_quiet_when_a_frame_fits
    prog = program do
      screen :bitmap
      game_loop do
        wait_vblank
        draw_rect_at 0, 0, 8, 8, :green
      end
    end
    assert_empty Check.new.detect(prog)
  end

  def test_quiet_for_a_static_program
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 100, 100, :red # heavy, but drawn once
      halt
    end
    assert_empty Check.new.detect(prog), "a one-shot draw has no per-frame tear risk"
  end

  # 3 clears/frame (115,200) overruns the brief single-buffer window (tears) but
  # fits a whole frame, so double-buffered it's quiet — the mode changes the budget.
  def test_buffered_is_judged_against_the_whole_frame_budget
    refute_empty Check.new.detect(loop_of_clears(3, buffered: false)), "single-buffer: tears"
    assert_empty Check.new.detect(loop_of_clears(3, buffered: true)), "buffered: fits a whole frame"
  end

  # Double buffering still has a ceiling: over a whole frame it warns, but about a
  # dropped frame rate, not tearing (buffering makes tearing impossible).
  def test_buffered_over_a_whole_frame_warns_about_frame_rate_not_tearing
    findings = Check.new.detect(loop_of_clears(7, buffered: true)) # 268,800 > 240,000
    assert_equal 1, findings.length
    assert_match(/frame rate|60 frames|choppy/, findings.first.message)
    # It reassures ("won't tear"), it does NOT raise the alarm the single-buffer
    # message does about the picture tearing.
    refute_match(/may tear or flicker/, findings.first.message)
  end

  # A game that runs some scenes direct-color and others tear-free, dispatched by
  # :state — each scene clearing the whole screen a given number of times a frame.
  def mixed(direct_clears:, buffered_clears:)
    Build.program(
      Build.screen(:bitmap), # boot: direct
      Build.set(:state, Build.int(0)),
      Build.func(:_scene_still, *Array.new(direct_clears) { Build.clear_screen(:black) }),
      Build.func(:_scene_action, Build.screen(:bitmap, buffered: true),
                 *Array.new(buffered_clears) { Build.clear_screen(:black) }),
      Build.loop_(Build.wait_vblank, Build.case_(:state, [[0, :_scene_still], [1, :_scene_action]])),
    )
  end

  # A heavy direct-color scene tears even when a buffered scene shares the game.
  # Per-scene budgets catch it and name it; the buffered scene, on its own wider
  # budget, stays quiet. (The old whole-program budget hid the direct scene.)
  def test_a_heavy_direct_scene_warns_even_beside_a_buffered_one
    findings = Check.new.detect(mixed(direct_clears: 3, buffered_clears: 1)) # direct 115,200 > 80,000
    assert_equal 1, findings.length
    assert_match(/still/, findings.first.message) # names the offending scene
    assert_match(/tear/, findings.first.message)
  end

  # When the heavy scene is the buffered one (over a whole frame), the warning is
  # about frame rate, not tearing; the light direct scene stays quiet.
  def test_a_heavy_buffered_scene_warns_about_frame_rate_not_tearing
    findings = Check.new.detect(mixed(direct_clears: 1, buffered_clears: 7)) # buffered 268,800 > 240,000
    assert_equal 1, findings.length
    assert_match(/action/, findings.first.message)
    assert_match(/frame rate|60 frames|choppy/, findings.first.message)
  end

  # Both scenes comfortably within their own budgets: quiet.
  def test_quiet_when_each_scene_fits_its_own_mode
    assert_empty Check.new.detect(mixed(direct_clears: 1, buffered_clears: 3))
  end

  # It fires during a real build — printed to err — without stopping the ROM.
  def test_build_prints_the_warning_but_still_produces_a_rom
    err = StringIO.new
    rom = RubyGBA.build("HEAVY", code: "BHVY", maker: "01", err: err) do
      screen :bitmap
      game_loop do
        wait_vblank
        repeat(100) { |_i| clear_screen :black }
      end
    end
    assert_operator rom.size, :>, 0
    assert_match(/tear/, err.string)
  end
end

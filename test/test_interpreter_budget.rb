# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The reference interpreter runs an endless game loop until a step budget. When it stops,
# it must stop at a FRAME BOUNDARY — never mid-frame, which would leave a torn, half-drawn
# screen (a clear ran, only some of the frame's draws landed). A caller reading i.screen
# after an unbounded run should always see a complete, settled frame. A program with no
# frames at all (a tight compute loop) still stops at the budget and never hangs.
class TestInterpreterBudget < Minitest::Test
  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  Build = RubyGBA::IR::Build
  Color = RubyGBA::Color

  # A game loop that fills red, does a chunk of per-frame work, then draws a marker LAST.
  # The screen ends every frame showing the marker; a mid-frame cutoff would show red.
  def marker_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop do
        wait_vblank
        clear_screen :red
        repeat(400) { |_k| pixel 120, 80, :blue } # bulk work, so a cutoff lands inside a frame
        fill_rect 0, 0, 8, 8, :green               # the "frame complete" marker, drawn last
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_budget_cutoff_stops_at_a_frame_boundary_not_mid_frame
    i = Reference.new.run(marker_program, max_steps: 1000) # endless loop -> runs to the step budget
    assert_equal Color.resolve(:green), i.screen.pixel(2, 2),
                 "the cutoff should finish the in-flight frame (marker drawn), not tear it mid-draw"
  end

  def test_it_still_reports_that_the_budget_was_reached
    i = Reference.new.run(marker_program, max_steps: 1000)
    assert i.stopped_at_budget?, "an endless loop still hits the budget; it just stops cleanly"
  end

  # A program with no frames (no wait_vblank) can't 'finish a frame', so it stops at the
  # budget as before — and never runs away.
  def test_a_frameless_loop_stops_at_the_budget
    i = Reference.new.run(Build.program(Build.loop_(Build.add(:x, 1))), max_steps: 100)
    assert i.stopped_at_budget?
    assert_operator i[:x], :<=, 150, "a frame-less loop stops near the budget, not at a runaway multiple"
  end
end

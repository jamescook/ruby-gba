# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The structural render-budget guardrail: warn when a game clears the whole screen
# and repaints a GROWING collection every frame — the "rebuild the whole frame from
# scratch" pattern that tears once the collection grows. Cheap and high-signal (no
# cost weights); it only looks at the steady per-frame path, so a once-per-round
# repaint behind a press is (correctly) left alone.
class TestRedrawEverythingGuardrail < Minitest::Test
  Builder = RubyGBA::Builder
  Check = RubyGBA::IR::Guardrails::Checks::RedrawEverything
  Build = RubyGBA::IR::Build

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def test_flags_clear_plus_growing_list_redraw_every_frame
    prog = program do
      screen :bitmap
      body = list :body, capacity: 64
      game_loop do
        wait_vblank
        clear_screen :black
        repeat(body.length) { |_i| draw_rect_at 0, 0, 8, 8, :green }
      end
    end
    findings = Check.new.detect(prog)
    assert_equal 1, findings.length
    assert findings.first.warning?, "structural check is advisory, not an error"
    assert_match(/tear/, findings.first.message)
    assert_equal :loop, findings.first.node.kind, "it blames the loop that rebuilds the frame"
  end

  # The headline false-positive guard: the shipped incremental Snake clears on its
  # menus and repaints the whole board in new_game — but new_game is behind
  # pressed(:start), a once-per-round transition, so it must NOT be flagged.
  def test_does_not_flag_the_incremental_snake
    require_relative "../examples/snake"
    assert_empty Check.new.detect(Snake.program),
                 "the incremental Snake draws per-cell in the steady loop; only its menus clear"
  end

  # The clear+growing-redraw pattern is exactly what double buffering is FOR: it
  # can't tear when buffered, so this tear-specific warning stays quiet. (If the
  # redraw is genuinely too heavy, the draw-budget check catches the frame-rate
  # drop — that's a different concern.)
  def test_quiet_when_buffered
    prog = Build.program(
      Build.screen(:bitmap, buffered: true),
      Build.list_new(:body, 64),
      Build.loop_(
        Build.wait_vblank,
        Build.clear_screen(:black),
        Build.repeat(Build.list_len(:body), :i, Build.draw_rect_at(0, 0, 8, 8, :green)),
      ),
    )
    assert_empty Check.new.detect(prog), "double buffering makes this pattern tear-proof"
  end

  # The same shape single-buffered still trips it — proving the quiet above is the
  # buffered flag's doing, not the IR-built shape slipping past the detector.
  def test_the_same_shape_single_buffered_still_trips_it
    prog = Build.program(
      Build.screen(:bitmap, buffered: false),
      Build.list_new(:body, 64),
      Build.loop_(
        Build.wait_vblank,
        Build.clear_screen(:black),
        Build.repeat(Build.list_len(:body), :i, Build.draw_rect_at(0, 0, 8, 8, :green)),
      ),
    )
    assert_equal 1, Check.new.detect(prog).length
  end

  # No clear -> not this footgun (a different concern — leftover trails).
  def test_quiet_without_a_full_clear
    prog = program do
      screen :bitmap
      body = list :body, capacity: 64
      game_loop do
        wait_vblank
        repeat(body.length) { |_i| draw_rect_at 0, 0, 8, 8, :green }
      end
    end
    assert_empty Check.new.detect(prog)
  end

  # A fixed-count redraw is bounded — it doesn't grow, so it's fine.
  def test_quiet_when_the_redraw_count_is_fixed
    prog = program do
      screen :bitmap
      game_loop do
        wait_vblank
        clear_screen :black
        repeat(4) { |_i| draw_rect_at 0, 0, 8, 8, :green }
      end
    end
    assert_empty Check.new.detect(prog)
  end

  # A clear + growing-list redraw behind a press is a transition, not steady work.
  def test_quiet_when_the_redraw_is_behind_a_press_transition
    prog = program do
      screen :bitmap
      body = list :body, capacity: 64
      func :repaint do
        clear_screen :black
        repeat(body.length) { |_i| draw_rect_at 0, 0, 8, 8, :green }
      end
      game_loop do
        wait_vblank
        pressed(:start).then { call :repaint }
        draw_rect_at 0, 0, 8, 8, :white # steady work: one cell, no clear
      end
    end
    assert_empty Check.new.detect(prog)
  end
end

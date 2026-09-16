# frozen_string_literal: true

require "test_helper"
require "differential"

# `draw_rect_at` is the one bitmap-drawing verb whose whole purpose is a position the
# game WORKS OUT as it runs — which is the one kind of position that can land off an
# edge. Its neighbors (`blit`, `draw_column_at`) clip themselves at run time; this one
# didn't, so a rect that ran past the right edge of the screen — or of an `inside` area
# — wrapped onto the row below instead of stopping, both in plain bitmap mode and on
# the tear-free screen.
#
# Every case here is asserted with a whole-screen differential (see test/differential.rb):
# the interpreter always clipped correctly, so any pixel the console painted outside
# where the interpreter did is exactly the wrap this test exists to catch.
class TestDrawRectAtClipping < Minitest::Test
  include Differential

  AREA = [40, 30, 120, 80].freeze # x, y, w, h — well off every edge of the screen

  def program(tear_free: false, &block)
    b = Builder.new
    b.instance_eval do
      tear_free ? (screen :bitmap, tear_free: true, colors: [:black, :red]) : (screen :bitmap)
    end
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # --- past a screen edge, no `inside` in force ---

  def test_past_the_right_edge_of_the_screen
    prog = program { game_loop { draw_rect_at 236, 60, 8, 8, :red } }
    assert_backends_agree(prog, name: "DRAR")
  end

  def test_past_the_left_edge_of_the_screen
    prog = program { game_loop { draw_rect_at(-4, 60, 8, 8, :red) } }
    assert_backends_agree(prog, name: "DRAL")
  end

  def test_past_the_top_edge_of_the_screen
    prog = program { game_loop { draw_rect_at 100, -4, 8, 8, :red } }
    assert_backends_agree(prog, name: "DRAT")
  end

  def test_past_the_bottom_edge_of_the_screen
    prog = program { game_loop { draw_rect_at 100, 156, 8, 8, :red } }
    assert_backends_agree(prog, name: "DRAB")
  end

  # --- past an `inside` area's own edges ---

  def test_past_the_right_edge_of_an_area
    prog = program { game_loop { inside(*AREA) { draw_rect_at 152, 60, 16, 16, :red } } }
    assert_backends_agree(prog, name: "DAAR")
  end

  def test_past_the_left_edge_of_an_area
    prog = program { game_loop { inside(*AREA) { draw_rect_at 32, 60, 16, 16, :red } } }
    assert_backends_agree(prog, name: "DAAL")
  end

  def test_past_the_top_edge_of_an_area
    prog = program { game_loop { inside(*AREA) { draw_rect_at 100, 22, 16, 16, :red } } }
    assert_backends_agree(prog, name: "DAAT")
  end

  def test_past_the_bottom_edge_of_an_area
    prog = program { game_loop { inside(*AREA) { draw_rect_at 100, 102, 16, 16, :red } } }
    assert_backends_agree(prog, name: "DAAB")
  end

  # --- a run-time width straddling an edge (the health-bar shape) ---

  def test_a_run_time_width_straddling_the_right_edge
    prog = program do
      w = var :w, 20
      game_loop { draw_rect_at 236, 60, w, 8, :red }
    end
    assert_backends_agree(prog, name: "DRWW")
  end

  # --- the same, on the tear-free screen ---

  def test_past_the_right_edge_of_the_screen_tear_free
    prog = program(tear_free: true) { game_loop { draw_rect_at 236, 60, 8, 8, :red } }
    assert_backends_agree(prog, name: "TFAR")
  end

  def test_past_the_right_edge_of_an_area_tear_free
    prog = program(tear_free: true) { game_loop { inside(*AREA) { draw_rect_at 152, 60, 16, 16, :red } } }
    assert_backends_agree(prog, name: "TFAA")
  end

  def test_a_run_time_width_straddling_the_right_edge_tear_free
    prog = program(tear_free: true) do
      w = var :w, 20
      game_loop { draw_rect_at 236, 60, w, 8, :red }
    end
    assert_backends_agree(prog, name: "TFWW")
  end

  # A width settled while building but a position the game works out — the shape that
  # keeps the fast, size-chosen row a fixed rectangle gets (see
  # Backends::GBA::Buffered#emit_draw_rect_at_buffered_fixed_width) for the common case
  # where it turns out to fit whole, and falls back to the general clip only when it
  # actually crosses an edge, as it does here.
  def test_a_fixed_width_moving_position_straddling_the_right_edge_tear_free
    prog = program(tear_free: true) do
      x = var :x, 236
      game_loop { draw_rect_at x, 60, 8, 8, :red }
    end
    assert_backends_agree(prog, name: "TFFW")
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The draw-cost model: how much drawing a program does in one frame, so a game can
# be told when it draws more than the console can finish before the screen tears.
#
# These tests build tiny programs through the DSL and assert the exact estimate, so
# the arithmetic is checkable by eye. Costs are in "write-units" — roughly one
# framebuffer write — under simple, deliberately round default weights:
#
#   * a filled/plotted pixel        → 1 write        (fill_rect / draw_rect_at / pixel)
#   * a clear of the whole screen   → 240*160 = 38,400
#   * a text glyph (5x7 font)       → 35 writes
#
# The weights are rough placeholders (real ones come from measuring on hardware);
# what's under test here is the model's *logic* — summing, loop multiplication,
# worst-branch dispatch — not the exact calibration.
class TestCostModel < Minitest::Test
  Builder = RubyGBA::Builder
  Cost = RubyGBA::IR::CostModel

  # Build a program through the DSL (same route as the other DSL tests).
  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A static program's frame cost is just the sum of its draws' pixel areas.
  def test_static_draws_sum_their_pixel_area
    prog = program do
      display :bitmap
      fill_rect 0, 0, 10, 10, :red   # 10*10 = 100
      fill_rect 0, 0, 4, 4, :blue    #  4*4  =  16
      halt
    end
    assert_equal 116, Cost.new.frame_cost(prog)
  end

  # A repeat runs its body a fixed number of times, so its cost multiplies.
  def test_repeat_multiplies_its_body
    prog = program do
      display :bitmap
      repeat(3) { |_i| draw_rect_at 0, 0, 8, 8, :green } # 3 * (8*8) = 192
      halt
    end
    assert_equal 192, Cost.new.frame_cost(prog)
  end

  # A repeat over a list is bounded by the list's CAPACITY — the worst case we can
  # prove at build time — not by how many items happen to be in it right now.
  def test_repeat_over_a_list_uses_its_capacity
    prog = program do
      display :bitmap
      body = list :body, capacity: 8
      body.push 1                                          # only 1 item now...
      repeat(body.length) { |i| draw_rect_at 0, 0, 8, 8, :green }
      halt
    end
    # ...but the estimate assumes the worst: 8 (capacity) * 64 = 512.
    assert_equal 512, Cost.new.frame_cost(prog)
  end

  # Inside a game loop, case_var runs exactly ONE scene per frame, so the per-frame
  # cost is the worst branch, not the sum of all branches.
  def test_case_var_costs_the_worst_branch_not_the_sum
    prog = program do
      display :bitmap
      var :state, 0
      scene(:light) { draw_rect_at 0, 0, 2, 2, :red }    #  2*2  =   4
      scene(:heavy) { draw_rect_at 0, 0, 10, 10, :red }  # 10*10 = 100
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :light
          when_val 1, :heavy
        end
      end
    end
    assert_equal 100, Cost.new.frame_cost(prog) # max(4, 100), not 104
  end

  # The frame cost is the game LOOP's per-frame work — boot-time setup outside the
  # loop doesn't count against the frame budget.
  def test_only_the_loop_body_counts_toward_the_frame
    prog = program do
      display :bitmap
      fill_rect 0, 0, 20, 20, :white  # boot draw (400) — NOT per frame
      game_loop do
        wait_vblank
        draw_rect_at 0, 0, 8, 8, :green # per-frame: 64
      end
    end
    assert_equal 64, Cost.new.frame_cost(prog)
  end

  # Weights are configurable (Postgres-GUC style): a dev can tune them or weight an
  # op up to discourage it. Doubling the pixel weight doubles a pixel-area cost.
  def test_weights_are_configurable
    prog = program do
      display :bitmap
      fill_rect 0, 0, 10, 10, :red # 100 pixels
      halt
    end
    assert_equal 200, Cost.new(pixel: 2).frame_cost(prog)
  end

  # A static program reports its one-time boot draw.
  def test_report_states_the_boot_cost_of_a_static_program
    prog = program do
      display :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    Cost.new.report(prog, out: io)
    assert_match(/boot draw ~ 100 /, io.string)
    assert_match(/drawn once/, io.string)
  end

  # A game loop that draws far more than a frame's budget is flagged.
  def test_report_flags_a_loop_that_overruns_the_budget
    prog = program do
      display :bitmap
      game_loop do
        wait_vblank
        repeat(100) { |_i| clear_screen :black } # 100 * 38,400 ≫ budget
      end
    end
    io = StringIO.new
    Cost.new.report(prog, out: io)
    assert_match(/over budget/, io.string)
  end

  # A ROM built through RubyGBA.build can report on itself.
  def test_a_built_rom_explains_itself
    rom = RubyGBA.build("EXPLAIN", code: "BXPL", maker: "01") do
      display :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    rom.explain(out: io)
    assert_match(/boot draw ~ 100 /, io.string)
  end
end

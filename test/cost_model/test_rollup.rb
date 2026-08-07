# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# How often a frame pays for an op (lib/ruby_gba/ir/cost_model/rollup.rb): loops
# multiply, a scene dispatch takes its heaviest branch, and the recurring load
# discounts work that does not happen every frame.
class TestCostRollup < CostModelTest
  # A static program's frame cost is just the sum of its draws.
  def test_static_draws_sum_their_pixel_area
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red   # 10*10 = 100
      fill_rect 0, 0, 4, 4, :blue    #  4*4  =  16
      halt
    end
    near plot_rect(10, 10) + plot_rect(4, 4), Cost.new.frame_cost(prog)
  end

  # A repeat runs its body a fixed number of times, so its cost multiplies.
  def test_repeat_multiplies_its_body
    prog = program do
      screen :bitmap
      repeat(3) { |_i| draw_rect_at 0, 0, 8, 8, :green } # 3 * one 8x8 rect
      halt
    end
    near 3 * dma_rows(8, 8), Cost.new.frame_cost(prog)
  end

  # A repeat over a list is bounded by the list's CAPACITY — the worst case we can
  # prove at build time — not by how many items happen to be in it right now.
  def test_repeat_over_a_list_uses_its_capacity
    prog = program do
      screen :bitmap
      body = list :body, capacity: 8
      body.push 1                                          # only 1 item now...
      repeat(body.length) { |i| draw_rect_at 0, 0, 8, 8, :green }
      halt
    end
    # ...but the estimate assumes the worst: 8 (capacity) * one 8x8 rect, plus the
    # one-time push that seeded the list (a single logic step).
    near (8 * dma_rows(8, 8)) + WEIGHTS[:op_step], Cost.new.frame_cost(prog)
  end

  # Inside a game loop, case_var runs exactly ONE scene per frame, so the per-frame
  # cost is the worst branch, not the sum of all branches.
  def test_case_var_costs_the_worst_branch_not_the_sum
    prog = program do
      screen :bitmap
      var :state, 0
      scene(:light) { draw_rect_at 0, 0, 2, 2, :red }    #  2*2  =   4
      scene(:heavy) { draw_rect_at 0, 0, 10, 10, :red }  # 10*10 = 100
      game_loop do
        case_var(:state) do
          when_val 0, :light
          when_val 1, :heavy
        end
      end
    end
    near dma_rows(10, 10), Cost.new.frame_cost(prog) # the heavy branch, not the sum of both
  end

  # The frame cost is the game LOOP's per-frame work — boot-time setup outside the
  # loop doesn't count against the frame budget.
  def test_only_the_loop_body_counts_toward_the_frame
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 20, 20, :white  # boot draw (400) — NOT per frame
      game_loop do
        draw_rect_at 0, 0, 8, 8, :green # per-frame
      end
    end
    near dma_rows(8, 8), Cost.new.frame_cost(prog) # the boot fill (20x20) is excluded
  end

  # --- selectivity: cost hints scale work by how often it actually runs ---

  # every(k) runs one frame in k, so its body contributes 1/k to the STEADY
  # per-frame cost — the tear risk — while frame_cost still reports the full cost
  # on the frame it fires.
  def test_every_body_contributes_a_kth_to_the_steady_cost
    prog = program do
      screen :bitmap
      game_loop do
        every(4) { draw_rect_at 0, 0, 8, 8, :green } # 64 when it fires
      end
    end
    near dma_rows(8, 8), Cost.new.frame_cost(prog)      # full cost on the frame it fires
    near dma_rows(8, 8) / 4.0, Cost.new.steady_cost(prog) # spread across 4 frames
  end

  # after(n) fires exactly once, ever, so it contributes nothing to the steady
  # per-frame figure, though its full cost still shows on the frame it fires. The
  # cost model reads this straight from the `after` node kind.
  def test_after_body_is_a_one_shot_and_drops_out_of_steady_cost
    prog = program do
      screen :bitmap
      game_loop do
        after(30) { draw_rect_at 0, 0, 8, 8, :green } # once, on the frame it fires
      end
    end
    near dma_rows(8, 8), Cost.new.frame_cost(prog)
    assert_equal 0, Cost.new.steady_cost(prog)
  end

  # With no cost hints, the steady figure equals the full frame cost.
  def test_steady_equals_full_when_nothing_is_gated
    prog = program do
      screen :bitmap
      game_loop do
        draw_rect_at 0, 0, 8, 8, :green # runs every frame
      end
    end
    assert_equal Cost.new.frame_cost(prog), Cost.new.steady_cost(prog)
  end

  # A pressed edge is rare, so a body it gates is a transition spike, not steady
  # per-frame work — it drops out of steady_cost.
  def test_pressed_guarded_body_drops_out_of_steady_cost
    prog = program do
      screen :bitmap
      game_loop do
        pressed(:start).then { draw_rect_at 0, 0, 8, 8, :green } # 64 on a press frame only
      end
    end
    near dma_rows(8, 8), Cost.new.frame_cost(prog) # full cost on the press frame
    assert_equal 0, Cost.new.steady_cost(prog)     # not part of the every-frame load
  end

  # held is level, not an edge — it can run every frame it's down, so it counts
  # fully toward steady.
  def test_held_guarded_body_counts_fully_toward_steady
    prog = program do
      screen :bitmap
      game_loop do
        held(:right).then { draw_rect_at 0, 0, 8, 8, :green }
      end
    end
    near dma_rows(8, 8), Cost.new.steady_cost(prog)
  end

  # chance(p) holds p% of the time, so a gated body counts at p%.
  def test_chance_body_counts_at_its_probability
    gated = program do
      screen :bitmap
      game_loop do
        chance(25).then { draw_rect_at 0, 0, 8, 8, :green } # one 8x8 rect, 25% of frames
      end
    end
    # The roll runs every frame; isolate it with an empty-bodied roll so this asserts
    # the SELECTIVITY (the body counts at 25%) without pinning the roll's own cost.
    roll_only = program do
      screen :bitmap
      game_loop do
        chance(25).then { nil }
      end
    end
    overhead = Cost.new.steady_cost(roll_only)
    near overhead + (dma_rows(8, 8) * 0.25), Cost.new.steady_cost(gated)
  end

  def test_a_game_that_might_collide_is_not_reported_over_budget
    prog = near_misses
    walk = 6 * 16 * 16 * WEIGHTS[:overlap_pixel]

    assert_operator walk, :>, 228, "the worst case really does exceed a frame"
    assert_operator Cost.new.frame_cost(prog), :>=, walk, "and the worst case still counts it"
    assert_operator Cost.new.steady_cost(prog), :<, 228, "but the recurring load must not"
  end

  # --- naming the arithmetic a statement hides ---

  # Arithmetic dearer than a plain step gets a line of its own, so it can be seen. A
  # divide used to be priced right and then labelled with the statement it fed, which
  # left the dearest thing in a program reading as "set".
  def test_a_divide_gets_a_line_of_its_own_beside_the_statement_it_feeds
    prog = program do
      screen :bitmap
      step = var :step, 3
      x = var :x, 100
      game_loop { x.set(x / step) }
    end
    labels = leaves(Cost.new.analyze(prog)).map { |n| n[:label] }
    assert_includes labels, "divide (worked out)"
    assert_includes labels, "set", "the statement it feeds is still there, at what is left"
  end

  # Naming the arithmetic only splits what was already counted — it must not change,
  # lose or double any of it. Checked against #steady_cost, which prices the same frame
  # without building a tree at all, so the two paths have to agree.
  def test_naming_the_arithmetic_does_not_change_what_a_frame_costs
    prog = program do
      screen :bitmap
      step = var :step, 3
      x = var :x, 100
      game_loop { x.set((x / step) + (x / 100) + (x * 7)) }
    end
    cost = Cost.new
    near cost.steady_cost(prog), leaves(cost.analyze(prog)).sum { |n| n[:cost] }
  end

  # A power of two is a shift, no dearer than an add, so it gets no line of its own.
  # Naming it would cry wolf on the one divide an author never has to think about.
  def test_a_divide_by_a_power_of_two_is_not_singled_out
    prog = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(x / 64) }
    end
    labels = leaves(Cost.new.analyze(prog)).map { |n| n[:label] }
    assert_empty labels.grep(/divide/), "a shift is not worth a line of its own"
  end

  # The three divides differ by five times, and which one you have is something an
  # author can act on — make the divisor a fixed number, precompute a table. One word
  # for all three would hide exactly that.
  def test_the_three_divide_tiers_are_named_apart
    prog = program do
      screen :bitmap
      step = var :step, 3
      x = var :x, 100
      depth = var :depth, 4.0
      scale = var :scale, 2.0
      game_loop do
        x.set(x / step)        # a divisor the game works out
        x.set(x / 100)         # a number written into the program
        depth.set(depth / scale) # two numbers that hold a fraction
      end
    end
    labels = leaves(Cost.new.analyze(prog)).map { |n| n[:label] }.grep(/divide/)
    assert_equal ["divide (worked out)", "divide (fixed number)", "divide (fraction)"], labels
  end

  # Splitting the arithmetic out must not move cost between the drawing / sound / logic
  # sections: a width the game divides out is part of what drawing that rectangle costs,
  # and the drawing subtotal is what the tear check reads.
  def test_arithmetic_stays_in_the_section_of_the_statement_that_pays_for_it
    prog = program do
      screen :bitmap
      step = var :step, 3
      w = var :w, 40
      game_loop { draw_rect_at 0, 0, (w / step), 8, :red }
    end
    drawing = Cost.new.category_tree(prog).find { |c| c[:category] == :drawing }
    refute_nil drawing, "the divide belongs to the rectangle it sizes, so drawing keeps it"
    assert_includes leaves([drawing]).map { |n| n[:label] }, "divide (worked out)"
  end
end

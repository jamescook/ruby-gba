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

  # A repeat runs its body a fixed number of times, so its cost multiplies — and so does
  # going round, which is not free either.
  def test_repeat_multiplies_its_body_and_the_pass_around_it
    prog = program do
      screen :bitmap
      repeat(3) { |_i| draw_rect_at 0, 0, 8, 8, :green } # 3 * (one 8x8 rect + one pass)
      halt
    end
    near loop_cost(3, dma_rows(8, 8)), Cost.new.frame_cost(prog)
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
    # ...but the estimate assumes the worst: 8 (capacity) passes of one 8x8 rect, plus the
    # one-time push that seeded the list.
    near loop_cost(8, dma_rows(8, 8)) + WEIGHTS[:list_write], Cost.new.frame_cost(prog)
  end

  # ...THE WORST CASE. The every-frame load asks the other question, and the capacity is the
  # wrong answer to it: a list is sized so it can never overflow, so it is nearly never full,
  # and a snake's body list is sized for the whole board while holding four cells for most of
  # a game. Counting the ceiling every frame made a snake that measures 49 scanlines report
  # 106 of its 228 — and the walk is the biggest line in that frame, so it was not a rounding
  # error, it was the answer.
  def test_the_every_frame_load_counts_a_list_walk_at_what_it_usually_holds
    prog = walking_game(capacity: 64, estimate: { usually: 4 })

    near frame_boundary + loop_cost(64, dma_rows(8, 8)), Cost.new.frame_cost(prog), "the worst it can reach"
    near frame_boundary + loop_cost(4, dma_rows(8, 8)), Cost.new.steady_cost(prog), "what a frame usually pays"
  end

  # Said nothing, and the estimate has to answer anyway. It guesses — a quarter of the
  # capacity — because the alternative is to keep charging a ceiling nobody plays, and an
  # estimate that cries wolf on a game that fits teaches an author to stop reading it. The
  # report says which of the two numbers it used, so the guess is never silent.
  def test_a_list_that_says_nothing_is_counted_at_a_quarter_of_its_capacity
    prog = walking_game(capacity: 64)

    near frame_boundary + loop_cost(64, dma_rows(8, 8)), Cost.new.frame_cost(prog)
    near frame_boundary + loop_cost(16, dma_rows(8, 8)), Cost.new.steady_cost(prog)
  end

  # A range says a length that moves, and the TOP is what a frame is charged: the dearest of
  # the frames that usually happen. It is also what stops a range being a way to talk the
  # estimate down — a wider one always reads dearer.
  def test_a_range_is_counted_at_its_top
    top = Cost.new.steady_cost(walking_game(capacity: 64, estimate: { usually: 4..12 }))

    near Cost.new.steady_cost(walking_game(capacity: 64, estimate: { usually: 12 })), top
  end

  # A game loop that walks a list of `capacity` items, drawing one rect each.
  def walking_game(capacity:, estimate: nil)
    program do
      screen :bitmap
      body = list :body, capacity: capacity, estimate: estimate
      game_loop { repeat(body.length) { |_i| draw_rect_at 0, 0, 8, 8, :green } }
    end
  end

  # A POOL ASKS THE SAME QUESTION AND WANTS A DIFFERENT ANSWER. Its walk really does go
  # round every slot, so those passes are real and are counted whole — what is not real is
  # running the BODY sixty-four times. It sits behind a test on whether the slot is live,
  # and a pool is sized for the worst moment of a game rather than a normal one.
  #
  # So the two are separated here, and the shape says it: whatever the pool usually holds,
  # taking one body per live slot back off leaves the SAME walk every time.
  def test_a_pool_walks_every_slot_and_runs_its_body_only_for_the_live_ones
    body = dma_rows(8, 8)
    walks = [1, 4, 16, 64].map do |live|
      Cost.new.steady_cost(shooting_game(capacity: 64, estimate: { usually: live })) - (live * body)
    end

    assert_in_delta walks.first, walks.last, 1e-6,
                    "the walk over the slots is the same work however few of them are live"
    assert_equal 1, walks.map { |w| w.round(6) }.uniq.length, "and it does not drift in between"
    assert_operator walks.first, :>, 64 * WEIGHTS[:loop_pass_held],
                    "it is a real cost: sixty-four passes, each asking whether its slot is live"
  end

  # The worst case is untouched: every slot CAN be live, so the frame that has them all
  # counts them all. That is the number "a heavier frame reaches" reports, and it does not
  # move when the author says what a normal frame holds.
  def test_a_pools_worst_case_still_counts_every_slot
    few = shooting_game(capacity: 64, estimate: { usually: 4 })
    many = shooting_game(capacity: 64, estimate: { usually: 64 })

    near Cost.new.frame_cost(many), Cost.new.frame_cost(few)
    near Cost.new.frame_cost(many), Cost.new.steady_cost(many),
         "and saying every slot is live reads exactly what a pool read before it could say"
  end

  # Said nothing, and the estimate answers anyway — a quarter of the slots, the same guess
  # a list's unsaid length gets and for the same reason. The report says which number it
  # used, so the guess is never silent.
  def test_a_pool_that_says_nothing_counts_a_quarter_of_its_slots_live
    guessed = Cost.new.steady_cost(shooting_game(capacity: 64))

    near Cost.new.steady_cost(shooting_game(capacity: 64, estimate: { usually: 16 })), guessed
    assert_operator guessed, :<, Cost.new.steady_cost(shooting_game(capacity: 64, estimate: { usually: 64 })),
                    "a guess is still an answer — it must not fall back to charging every slot"
  end

  # A range works here for the same reason it works on a list — it is the same hint, read
  # by the same code — and it is charged at its top.
  def test_a_pools_range_is_counted_at_its_top
    top = Cost.new.steady_cost(shooting_game(capacity: 64, estimate: { usually: 4..12 }))

    near Cost.new.steady_cost(shooting_game(capacity: 64, estimate: { usually: 12 })), top
    assert_operator Cost.new.steady_cost(shooting_game(capacity: 64, estimate: { usually: 4 })), :<, top,
                    "the top and not the bottom — a wider range must never read cheaper"
  end

  # More live slots than the pool has is not an estimate, it is a mistake, and it would
  # read CHEAPER than the truth if it were let through — the one direction that matters.
  def test_a_pool_refuses_to_usually_hold_more_than_it_can
    error = assert_raises(ArgumentError) { shooting_game(capacity: 8, estimate: { usually: 20 }) }

    assert_match(/8 slots/, error.message)
    assert_raises(ArgumentError) { shooting_game(capacity: 8, estimate: { usually: 0 }) }
  end

  # A game loop that walks a pool of `capacity` bullets, drawing one rect per live one.
  def shooting_game(capacity:, estimate: nil)
    program do
      screen :bitmap
      bullets = pool :bullet, x: 0, y: 0, capacity: capacity, estimate: estimate
      game_loop { bullets.each { |_b| draw_rect_at 0, 0, 8, 8, :green } }
    end
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
    near frame_boundary + dma_rows(10, 10), Cost.new.frame_cost(prog) # the heavy branch, not the sum of both
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
    near frame_boundary + dma_rows(8, 8), Cost.new.frame_cost(prog) # the boot fill (20x20) is excluded
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
    near frame_boundary + dma_rows(8, 8), Cost.new.frame_cost(prog)      # full cost on the frame it fires
    near frame_boundary + (dma_rows(8, 8) / 4.0), Cost.new.steady_cost(prog) # spread across 4 frames
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
    near frame_boundary + dma_rows(8, 8), Cost.new.frame_cost(prog)
    near frame_boundary, Cost.new.steady_cost(prog), "nothing left but having a frame at all"
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
    near frame_boundary + dma_rows(8, 8), Cost.new.frame_cost(prog) # full cost on the press frame
    near frame_boundary, Cost.new.steady_cost(prog) # not part of the every-frame load
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
    near frame_boundary + dma_rows(8, 8), Cost.new.steady_cost(prog)
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
    walk = 6 * 32 * 32 * WEIGHTS[:overlap_pixel]

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
    labels = leaves(Cost.new.analyze(prog)).map(&:label)
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
    near cost.steady_cost(prog), leaves(cost.analyze(prog)).sum(&:cost)
  end

  # A power of two is a shift, no dearer than an add, so it gets no line of its own.
  # Naming it would cry wolf on the one divide an author never has to think about.
  def test_a_divide_by_a_power_of_two_is_not_singled_out
    prog = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(x / 64) }
    end
    labels = leaves(Cost.new.analyze(prog)).map(&:label)
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
    labels = leaves(Cost.new.analyze(prog)).map(&:label).grep(/divide/)
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
    drawing = Cost.new.category_tree(prog).find { |c| c.category == :drawing }
    refute_nil drawing, "the divide belongs to the rectangle it sizes, so drawing keeps it"
    assert_includes leaves([drawing]).map(&:label), "divide (worked out)"
  end
end

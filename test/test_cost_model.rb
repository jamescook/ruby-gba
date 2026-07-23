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

  # --- the structured cost tree (what rom.explain renders / dumps as JSON) ---

  # analyze returns draw leaves with their costs, top to bottom.
  def test_analyze_returns_draw_leaves_with_costs
    prog = program do
      display :bitmap
      fill_rect 0, 0, 10, 10, :red    # 100
      draw_rect_at 0, 0, 8, 8, :green # 64
      halt
    end
    tree = Cost.new.analyze(prog)
    assert_equal %i[fill_rect draw_rect_at], tree.map { |n| n[:op] }
    assert_equal [100, 64], tree.map { |n| n[:cost] }
  end

  # A repeat node carries its multiplied cost and keeps its per-iteration body.
  def test_analyze_repeat_node_multiplies_and_keeps_its_body
    prog = program do
      display :bitmap
      repeat(3) { |_i| draw_rect_at 0, 0, 8, 8, :green } # 3 * 64
      halt
    end
    rep = Cost.new.analyze(prog).find { |n| n[:op] == :repeat }
    assert_equal 192, rep[:cost]
    assert_equal 64, rep[:children].first[:cost] # per-iteration
  end

  # A case node's cost is its worst branch, but it keeps every branch's cost.
  def test_analyze_case_node_cost_is_the_worst_branch
    prog = program do
      display :bitmap
      var :state, 0
      scene(:light) { draw_rect_at 0, 0, 2, 2, :red }   # 4
      scene(:heavy) { draw_rect_at 0, 0, 10, 10, :red } # 100
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :light
          when_val 1, :heavy
        end
      end
    end
    cnode = Cost.new.analyze(prog).find { |n| n[:op] == :case }
    assert_equal 100, cnode[:cost]
    assert_equal [4, 100], cnode[:children].map { |b| b[:cost] }
  end

  # rom.explain(format: :json) emits structured data tests can parse directly.
  def test_json_explain_is_parseable_structured_data
    rom = RubyGBA.build("JSON", code: "BJSN", maker: "01") do
      display :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    rom.explain(format: :json, out: io)
    data = JSON.parse(io.string)
    assert_equal 100, data["frame_cost"]
    assert_equal false, data["looping"]
    assert_equal "fill_rect", data["tree"].first["op"]
  end

  # --- scoping transforms (data in, data out — the guts of the drill-down view) ---

  # Runs of identical sibling leaves fold into one "op ×N" node, cost summed.
  def test_aggregate_folds_identical_sibling_leaves
    tree = [
      { op: :fill_rect, label: "fill_rect 4x4", cost: 16, w: 4, h: 4, children: [] },
      { op: :fill_rect, label: "fill_rect 4x4", cost: 16, w: 4, h: 4, children: [] },
      { op: :pixel, label: "pixel", cost: 1, w: nil, h: nil, children: [] },
    ]
    agg = Cost.new.aggregate(tree)
    assert_equal 2, agg.length
    assert_equal 32, agg[0][:cost]
    assert_equal 2, agg[0][:count]
    assert_equal "fill_rect ×2", agg[0][:label]
  end

  # Different sizes stay distinct — a stripe isn't folded into a corner square.
  def test_aggregate_keeps_different_sizes_distinct
    tree = [
      { op: :fill_rect, label: "big", cost: 100, w: 10, h: 10, children: [] },
      { op: :fill_rect, label: "small", cost: 16, w: 4, h: 4, children: [] },
    ]
    assert_equal 2, Cost.new.aggregate(tree).length
  end

  # A subtree deeper than max_depth collapses to a leaf that remembers what it hid,
  # with its rolled-up cost intact.
  def test_prune_collapses_subtrees_below_max_depth
    tree = [{ op: :call, label: "call :x", cost: 200, children: [
      { op: :draw_rect_at, label: "d", cost: 100, children: [] },
      { op: :draw_rect_at, label: "d", cost: 100, children: [] },
    ] }]
    pruned = Cost.new.prune(tree, 0)
    assert_empty pruned[0][:children]
    assert_equal 2, pruned[0][:collapsed]
    assert_equal 200, pruned[0][:cost]
  end

  # The flat "profiler" view ranks op kinds by total cost.
  def test_hot_ops_ranks_op_kinds_by_total_cost
    tree = [
      { op: :clear_screen, label: "c", cost: 38_400, children: [] },
      { op: :draw_rect_at, label: "d", cost: 64, children: [] },
      { op: :draw_rect_at, label: "d", cost: 64, children: [] },
    ]
    hot = Cost.new.hot_ops(tree, 5)
    assert_equal :clear_screen, hot[0][:op]
    assert_equal 128, hot[1][:cost] # the two draw_rect_ats, summed
    assert_equal 2, hot[1][:count]
  end

  # --- selectivity: cost hints scale work by how often it actually runs ---

  # every(k) runs one frame in k, so its body contributes 1/k to the STEADY
  # per-frame cost — the tear risk — while frame_cost still reports the full cost
  # on the frame it fires.
  def test_every_body_contributes_a_kth_to_the_steady_cost
    prog = program do
      display :bitmap
      game_loop do
        wait_vblank
        every(4) { draw_rect_at 0, 0, 8, 8, :green } # 64 when it fires
      end
    end
    assert_equal 64, Cost.new.frame_cost(prog)  # full cost on the frame it fires
    assert_equal 16, Cost.new.steady_cost(prog) # 64 / 4, spread across frames
  end

  # With no cost hints, the steady figure equals the full frame cost.
  def test_steady_equals_full_when_nothing_is_gated
    prog = program do
      display :bitmap
      game_loop do
        wait_vblank
        draw_rect_at 0, 0, 8, 8, :green # runs every frame
      end
    end
    assert_equal Cost.new.frame_cost(prog), Cost.new.steady_cost(prog)
  end
end

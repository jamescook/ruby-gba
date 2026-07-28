# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Costs are in scanlines (measured on hardware — see the timing probe), so the
# expected values are derived from the model's own weights rather than hard-coded:
# a rectangle filled/copied by DMA costs per row (setup + pixels), a whole-screen
# clear is one DMA, a glyph is a fixed plot cost. Tests assert with a small delta
# (floats) or, better, assert the SHAPE (a tall rect costs more than a wide one of
# equal area; an opaque blit is cheaper than a transparent one) which doesn't move
# when the calibration is re-measured.
module CostArith
  WEIGHTS = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS

  def dma_rows(w, h) = (h * WEIGHTS[:dma_setup]) + (w * h * WEIGHTS[:dma_pixel])
  def dma_blob(pixels) = WEIGHTS[:dma_setup] + (pixels * WEIGHTS[:dma_pixel])
  # A glyph/text costs the pixels it plots, in the given font.
  def text_cost(text, font = :default) = RubyGBA::Fonts.get(font).text_pixels(text) * WEIGHTS[:plot_pixel]
  def digit_cost(font = :default) = RubyGBA::Fonts.get(font).max_glyph_pixels(("0".."9").to_a) * WEIGHTS[:plot_pixel]
  def near(expected, actual, msg = nil) = assert_in_delta(expected, actual, 1e-6, msg)
end

# The draw-cost model: how much drawing a program does in one frame, so a game can
# be told when it draws more than the console can finish before the screen tears.
#
# These tests build tiny programs through the DSL and check the estimate. Costs are
# in scanlines (measured on hardware — see the timing probe), and a scanline of
# drawing is priced by how it's drawn: a fill/blit/save is one DMA per row (setup
# plus a little per pixel), a whole-screen clear is one big DMA, a font glyph and a
# lone pixel are plotted (dearer). Rather than restate those measured numbers, the
# tests derive expectations from the model's own weights (via CostArith) or assert
# the SHAPE — that a repeat multiplies, a case takes its worst branch, a tall rect
# beats a wide one of equal area — which survives a re-calibration.
class TestCostModel < Minitest::Test
  include CostArith

  Builder = RubyGBA::Builder
  Cost = RubyGBA::IR::CostModel
  Build = RubyGBA::IR::Build

  # Build a program through the DSL (same route as the other DSL tests).
  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A game loop that clears the whole screen +n+ times a frame, single- or
  # double-buffered. Built straight from the IR so it can flip the buffered flag the
  # DSL doesn't expose yet.
  def loop_of_clears(n, buffered:)
    Build.program(
      Build.screen(:bitmap, buffered: buffered),
      Build.loop_(Build.wait_vblank, *Array.new(n) { Build.clear_screen(:black) }),
    )
  end

  # A blit costs its image's footprint (width x height), looked up from the bitmap
  # definition — so a game's sprites weigh in the estimate, not silently as zero.
  def test_blit_costs_its_image_footprint
    prog = Build.program(
      Build.screen(:bitmap),
      Build.bitmap(:ship, width: 8, height: 4, pixels: Array.new(32, 0).pack("v*"), transparent: nil),
      Build.loop_(Build.wait_vblank, Build.blit(:ship, Build.int(0), Build.int(0))),
    )
    near dma_rows(8, 4), Cost.new.steady_cost(prog) # opaque: one DMA per row
    near dma_rows(8, 4), Cost.new.frame_cost(prog)
  end

  # A DMA fill costs per ROW (each row is a DMA), so a tall-thin rectangle costs more
  # than a wide-flat one of the SAME pixel area.
  def test_a_tall_rect_costs_more_than_a_wide_one_of_equal_area
    tall = program { screen(:bitmap); fill_rect(0, 0, 4, 40, :red); halt }   # 40 rows
    wide = program { screen(:bitmap); fill_rect(0, 0, 40, 4, :red); halt }   # 4 rows, same 160px
    assert_operator Cost.new.frame_cost(tall), :>, Cost.new.frame_cost(wide),
                    "more rows = more DMA setups = more cost, even at equal area"
  end

  # An opaque image streams by DMA; a transparent one is plotted pixel by pixel, so
  # it costs far more for the same size.
  def test_a_transparent_blit_costs_more_than_an_opaque_one
    def blit_of(transparent)
      Build.program(
        Build.screen(:bitmap),
        Build.bitmap(:s, width: 8, height: 8, pixels: Array.new(64, 0).pack("v*"),
                         transparent: transparent),
        Build.loop_(Build.wait_vblank, Build.blit(:s, Build.int(0), Build.int(0))),
      )
    end
    assert_operator Cost.new.steady_cost(blit_of(0x8000)), :>, Cost.new.steady_cost(blit_of(nil))
  end

  # A static program's frame cost is just the sum of its draws.
  def test_static_draws_sum_their_pixel_area
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red   # 10*10 = 100
      fill_rect 0, 0, 4, 4, :blue    #  4*4  =  16
      halt
    end
    near dma_rows(10, 10) + dma_rows(4, 4), Cost.new.frame_cost(prog)
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
        wait_vblank
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
        wait_vblank
        draw_rect_at 0, 0, 8, 8, :green # per-frame
      end
    end
    near dma_rows(8, 8), Cost.new.frame_cost(prog) # the boot fill (20x20) is excluded
  end

  # Weights are configurable (Postgres-GUC style): a dev can tune them or weight an
  # op up to discourage it. Doubling the DMA weights doubles a DMA-fill's cost.
  def test_weights_are_configurable
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red
      halt
    end
    base = Cost.new.frame_cost(prog)
    doubled = Cost.new(dma_setup: WEIGHTS[:dma_setup] * 2, dma_pixel: WEIGHTS[:dma_pixel] * 2).frame_cost(prog)
    near 2 * base, doubled
  end

  # A static program reports its one-time boot draw.
  def test_report_states_the_boot_cost_of_a_static_program
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    Cost.new.report(prog, out: io)
    assert_match(/boot draw ~ .* scanlines/, io.string)
    assert_match(/drawn once/, io.string)
  end

  # A game loop that draws far more than a frame's budget is flagged.
  def test_report_flags_a_loop_that_overruns_the_budget
    prog = program do
      screen :bitmap
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
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    rom.explain(out: io)
    assert_match(/boot draw ~ .* scanlines/, io.string)
  end

  # --- the structured cost tree (what rom.explain renders / dumps as JSON) ---

  # analyze returns draw leaves with their costs, top to bottom.
  def test_analyze_returns_draw_leaves_with_costs
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red    # 100
      draw_rect_at 0, 0, 8, 8, :green # 64
      halt
    end
    tree = Cost.new.analyze(prog)
    assert_equal %i[fill_rect draw_rect_at], tree.map { |n| n[:op] }
    near dma_rows(10, 10), tree[0][:cost]
    near dma_rows(8, 8), tree[1][:cost]
  end

  # A repeat node carries its multiplied cost and keeps its per-iteration body.
  def test_analyze_repeat_node_multiplies_and_keeps_its_body
    prog = program do
      screen :bitmap
      repeat(3) { |_i| draw_rect_at 0, 0, 8, 8, :green } # 3 * 64
      halt
    end
    rep = Cost.new.analyze(prog).find { |n| n[:op] == :repeat }
    near 3 * dma_rows(8, 8), rep[:cost]
    near dma_rows(8, 8), rep[:children].first[:cost] # per-iteration
  end

  # A case node's cost is its worst branch, but it keeps every branch's cost.
  def test_analyze_case_node_cost_is_the_worst_branch
    prog = program do
      screen :bitmap
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
    near dma_rows(10, 10), cnode[:cost]
    near dma_rows(2, 2), cnode[:children][0][:cost]
    near dma_rows(10, 10), cnode[:children][1][:cost]
  end

  # rom.explain(format: :json) emits structured data tests can parse directly.
  def test_json_explain_is_parseable_structured_data
    rom = RubyGBA.build("JSON", code: "BJSN", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    rom.explain(format: :json, out: io)
    data = JSON.parse(io.string)
    near dma_rows(10, 10), data["frame_cost"]
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
      screen :bitmap
      game_loop do
        wait_vblank
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
        wait_vblank
        after(30) { draw_rect_at 0, 0, 8, 8, :green } # once, on the frame it fires
      end
    end
    near dma_rows(8, 8), Cost.new.frame_cost(prog)
    assert_equal 0, Cost.new.steady_cost(prog)
  end

  # rom.explain names the intent: a timed trigger reads as "every 30" in the cost
  # tree, because the interval survives on the IR node for the report to read.
  def test_rom_explain_names_a_timed_trigger
    prog = program do
      screen :bitmap
      game_loop do
        wait_vblank
        every(30) { draw_rect_at 0, 0, 8, 8, :green }
      end
    end
    io = StringIO.new
    Cost.new.render(prog, out: io)
    assert_match(/every 30/, io.string)
  end

  # With no cost hints, the steady figure equals the full frame cost.
  def test_steady_equals_full_when_nothing_is_gated
    prog = program do
      screen :bitmap
      game_loop do
        wait_vblank
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
        wait_vblank
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
        wait_vblank
        held(:right).then { draw_rect_at 0, 0, 8, 8, :green }
      end
    end
    near dma_rows(8, 8), Cost.new.steady_cost(prog)
  end

  # The cost model reads the node's font, so a denser/bigger font costs more: the
  # same digits drawn in the compact :tiny font plot fewer pixels than in :default.
  def test_the_cost_of_text_follows_the_node_font
    default = program { screen(:bitmap); draw_text("42", 0, 0, :white); halt }
    tiny    = program { screen(:bitmap); draw_text("42", 0, 0, :white, font: :tiny); halt }
    near text_cost("42", :default), Cost.new.frame_cost(default)
    near text_cost("42", :tiny), Cost.new.frame_cost(tiny)
    assert_operator Cost.new.frame_cost(tiny), :<, Cost.new.frame_cost(default), "tiny should cost less"
  end

  # A draw_number column is a single draw_digit node worth one glyph — there's no
  # ten-way fan-out in the tree to discount, so a column's full and steady costs are
  # both just one glyph (a 3-digit score is ~3 glyphs, not 30).
  def test_draw_number_column_costs_one_glyph
    prog = program do
      screen :bitmap
      var :score, 0
      game_loop do
        wait_vblank
        draw_number :score, 8, 8, :white, digits: 1 # one column -> one draw_digit
      end
    end
    # digits:1 draws exactly one glyph — plus the cheap arithmetic to pull the digit
    # out of the number. So the cost is one glyph's worth and change, never a phantom
    # fan-out to more columns (which would be two glyphs or more).
    assert_operator Cost.new.steady_cost(prog), :>=, digit_cost
    assert_operator Cost.new.steady_cost(prog), :<, 2 * digit_cost
    assert_operator Cost.new.frame_cost(prog), :>=, digit_cost
    assert_operator Cost.new.frame_cost(prog), :<, 2 * digit_cost
  end

  # chance(p) holds p% of the time, so a gated body counts at p%.
  def test_chance_body_counts_at_its_probability
    gated = program do
      screen :bitmap
      game_loop do
        wait_vblank
        chance(25).then { draw_rect_at 0, 0, 8, 8, :green } # one 8x8 rect, 25% of frames
      end
    end
    # The roll runs every frame; isolate it with an empty-bodied roll so this asserts
    # the SELECTIVITY (the body counts at 25%) without pinning the roll's own cost.
    roll_only = program do
      screen :bitmap
      game_loop do
        wait_vblank
        chance(25).then { nil }
      end
    end
    overhead = Cost.new.steady_cost(roll_only)
    near overhead + (dma_rows(8, 8) * 0.25), Cost.new.steady_cost(gated)
  end

  # --- mode-aware budget: double buffering draws to a hidden page, so it gets the
  # whole frame to draw (not just the brief safe window) and can't tear ---

  # The SAME drawing is judged against a different budget by mode: the brief
  # vblank window single-buffered, the whole frame (much larger) double-buffered.
  def test_buffered_screen_is_judged_against_the_whole_frame_budget
    single = loop_of_clears(3, buffered: false) # 3 whole-screen clears a frame
    double = loop_of_clears(3, buffered: true)

    # identical drawing work either way...
    near 3 * dma_blob(240 * 160), Cost.new.steady_cost(single)
    near 3 * dma_blob(240 * 160), Cost.new.steady_cost(double)

    # ...but a different budget applies, and only one calls it buffered.
    assert_equal Cost::VBLANK_BUDGET, Cost.new.budget_for(single) # the vblank window (68 scanlines)
    assert_equal Cost::FRAME_BUDGET, Cost.new.budget_for(double)  # the whole frame (228 scanlines)
    refute Cost.new.buffered?(single)
    assert Cost.new.buffered?(double)
  end

  # 115,200/frame is over the single-buffer window (so it tears) but under a whole
  # frame (so buffered it's fine) — the verdict wording says which.
  def test_verdict_wording_reflects_the_mode
    io = StringIO.new
    Cost.new.report(loop_of_clears(3, buffered: false), out: io)
    assert_match(/over budget — the screen tears/, io.string)

    io = StringIO.new
    Cost.new.report(loop_of_clears(3, buffered: true), out: io)
    assert_match(/ok — fits the frame/, io.string)
  end

  # Even double buffering has a ceiling: draw more than fits in a whole frame and
  # the frame rate drops (it still never tears).
  def test_buffered_over_a_whole_frame_reads_as_a_dropped_frame_not_tearing
    io = StringIO.new
    Cost.new.report(loop_of_clears(7, buffered: true), out: io) # 268,800 > 240,000
    assert_match(/over budget — the frame rate drops/, io.string)
    refute_match(/tears/, io.string)
  end

  # The JSON carries the applicable budget and the buffered flag, for tests/tools.
  def test_json_reports_the_mode_and_its_budget
    assert_equal Cost::FRAME_BUDGET, Cost.new.as_json(loop_of_clears(2, buffered: true))[:budget]
    assert_equal true, Cost.new.as_json(loop_of_clears(2, buffered: true))[:buffered]
    assert_equal false, Cost.new.as_json(loop_of_clears(2, buffered: false))[:buffered]
  end

  # --- logic / compute is no longer free (gba-lpak) ---

  # A loop whose body only does arithmetic — no drawing — still costs, and the cost
  # scales with how many times it runs. This is what lets the analysis see a
  # compute-bound loop (AI, physics) instead of reading it as free.
  def test_a_compute_loop_is_not_free_and_scales_with_its_count
    one = program do
      screen :bitmap
      var :x, 0
      game_loop { wait_vblank; repeat(1) { add :x, 1 } }
    end
    ten = program do
      screen :bitmap
      var :x, 0
      game_loop { wait_vblank; repeat(10) { add :x, 1 } }
    end
    c_one = Cost.new.steady_cost(one)
    c_ten = Cost.new.steady_cost(ten)

    assert_operator c_one, :>, 0, "a compute loop is not free"
    near c_one * 10, c_ten, "ten iterations cost about ten times one"
  end

  # A divide is priced well above an add, because on this CPU it traps into the BIOS
  # Div routine rather than running as a single instruction.
  def test_a_divide_costs_more_than_an_add
    adder = program do
      screen :bitmap
      x = var :x, 100
      game_loop { wait_vblank; x.set(x + 1) }
    end
    divider = program do
      screen :bitmap
      x = var :x, 100
      game_loop { wait_vblank; x.set(x / 2) }
    end

    assert_operator Cost.new.steady_cost(divider), :>, Cost.new.steady_cost(adder),
                    "a divide (BIOS routine) should cost more than an add"
  end

  # A collision test's comparison chain runs every frame, whether or not it hits, so
  # it carries a cost even when the response body is empty.
  def test_a_collision_condition_is_not_free
    prog = program do
      screen :bitmap
      x = var :x, 0
      hero = box x, 0, 8, 8
      wall = box 100, 0, 8, 8
      game_loop { wait_vblank; hero.overlaps?(wall).then { nil } }
    end

    assert_operator Cost.new.steady_cost(prog), :>, 0,
                    "the overlaps? comparisons cost even with an empty body"
  end
end

# Per-scene budgets: a game that runs some scenes in direct color and others
# tear-free can't be judged against one whole-program budget. Each scene is judged
# against its OWN mode's budget — the safe window for direct, the whole frame for
# tear-free — so a heavy direct scene is caught even when a buffered scene is also
# present (which, judged whole-program, would widen the budget and hide it).
class TestPerSceneCost < Minitest::Test
  include RubyGBA::IR::Build
  include CostArith

  Cost = RubyGBA::IR::CostModel

  # A two-scene game dispatched by :state: a direct-color scene and a tear-free
  # (buffered) one, each clearing the whole screen a given number of times a frame
  # (one clear = 240*160 pixels, one DMA). Built from the IR so each scene's
  # mode is explicit.
  def mixed(direct_clears:, buffered_clears:)
    program(
      screen(:bitmap),                       # boot: direct color
      set(:state, int(0)),
      func(:_scene_still, *Array.new(direct_clears) { clear_screen(:black) }), # inherits direct
      func(:_scene_action, screen(:bitmap, buffered: true),
           *Array.new(buffered_clears) { clear_screen(:black) }),             # declares tear-free
      loop_(wait_vblank, case_(:state, [[0, :_scene_still], [1, :_scene_action]])),
    )
  end

  # The same drawing work is judged differently by mode: a direct scene clearing
  # 3x a frame (115,200) overruns the brief safe window and tears; a buffered one
  # clearing 3x fits a whole frame and is fine.
  def test_each_scene_is_judged_against_its_own_mode_budget
    verdicts = Cost.new.scene_verdicts(mixed(direct_clears: 3, buffered_clears: 3))
    still  = verdicts.find { |s| s[:name] == "still" }
    action = verdicts.find { |s| s[:name] == "action" }

    assert_equal :direct, still[:mode]
    near 3 * dma_blob(240 * 160), still[:steady_cost]
    assert_equal Cost::VBLANK_BUDGET, still[:budget]
    assert still[:over], "a direct scene clearing 3x a frame overruns the safe window"

    assert_equal :buffered, action[:mode]
    near 3 * dma_blob(240 * 160), action[:steady_cost]
    assert_equal Cost::FRAME_BUDGET, action[:budget]
    refute action[:over], "the same work, buffered, fits a whole frame"
  end

  # Judging each scene against its OWN mode's budget is what catches a heavy direct
  # scene sitting beside a buffered one: the direct scene overruns the vblank window
  # (so it tears) even though its cost fits the wider whole-frame budget a buffered
  # scene gets — so a single program-wide budget would miss it.
  def test_a_heavy_direct_scene_is_caught_even_beside_a_buffered_one
    still = Cost.new.scene_verdicts(mixed(direct_clears: 3, buffered_clears: 1))
                    .find { |s| s[:name] == "still" }
    assert still[:over], "the direct scene tears on its own budget"
    assert_operator still[:steady_cost], :<, Cost::FRAME_BUDGET,
                    "yet it fits the wider whole-frame budget a buffered scene would get"
  end

  # The report prints a line per scene, each naming its mode and verdict.
  def test_report_breaks_down_per_scene
    io = StringIO.new
    Cost.new.report(mixed(direct_clears: 3, buffered_clears: 3), out: io)
    assert_match(/scene :still \(direct\).*tears/, io.string)
    assert_match(/scene :action \(tear-free\).*fits the frame/, io.string)
  end

  # The JSON carries the per-scene breakdown for tools, in dispatch order.
  def test_json_carries_the_per_scene_breakdown
    scenes = Cost.new.as_json(mixed(direct_clears: 3, buffered_clears: 3))[:scenes]
    assert_equal %w[still action], scenes.map { |s| s[:name] }
    assert_equal %i[direct buffered], scenes.map { |s| s[:mode] }
  end
end

# The headline outcome for the game developer: with selectivity, the estimator
# tells the truth about the SHIPPED (incremental) Snake — its steady per-frame work
# fits the budget, even though the full cost of a menu/transition frame (which
# repaints the whole board once) does not. Without selectivity the estimate would
# cry wolf on a game that plays tear-free.
class TestSnakeSteadyCost < Minitest::Test
  Cost = RubyGBA::IR::CostModel

  def test_incremental_snake_steady_fits_though_a_transition_frame_does_not
    require_relative "../examples/snake"
    model = Cost.new
    assert_operator model.steady_cost(Snake.program), :<=, Cost::VBLANK_BUDGET,
                    "steady per-frame work should fit — the game plays tear-free"
    assert_operator model.frame_cost(Snake.program), :>, Cost::VBLANK_BUDGET,
                    "a transition frame (whole-board repaint) is heavy — that's the spike selectivity discounts"
  end
end

# Sound is per-frame work too: playing a song re-checks every note against a frame
# counter on *every* frame (the score is unrolled into one comparison per note), so
# a long tune is real recurring work, and a beep is a small burst of sound-register
# writes. The model prices both in the same scanline unit as drawing, so they weigh
# against the same budget. Built straight from the IR so the score is explicit.
class TestSoundCost < Minitest::Test
  include RubyGBA::IR::Build
  include CostArith

  Cost = RubyGBA::IR::CostModel

  def song_frame_cost(notes) = (Cost::SONG_TICK * WEIGHTS[:sound_write]) + (notes * WEIGHTS[:note_check])

  # An +n+-note song: n [frame, frequency] events, looping at frame n.
  def song_of(n)
    song(:theme, events: Array.new(n) { |i| [i, 440] }, total_frames: n)
  end

  # A game that plays an +n+-note song every frame, optionally drawing +draw+ too.
  def music_game(n, draw: nil)
    program(
      screen(:bitmap),
      song_of(n),
      loop_(wait_vblank, play_song(:theme), *[draw].compact),
    )
  end

  # Playing a song costs one frame-counter check per note every frame, plus the
  # fixed cost of advancing and wrapping the counter.
  def test_playing_a_song_costs_a_check_per_note_every_frame
    # 10 notes: the fixed per-frame tick plus a check per note.
    near song_frame_cost(10), Cost.new.steady_cost(music_game(10))
    # twice the notes, ~twice the per-note work (the fixed tick is unchanged)
    near song_frame_cost(20), Cost.new.steady_cost(music_game(20))
  end

  # A beep is a small fixed burst of writes to the sound registers.
  def test_a_beep_costs_its_sound_register_writes
    prog = program(screen(:bitmap), enable_sound, loop_(wait_vblank, beep(440)))
    near Cost::BEEP_WRITES * WEIGHTS[:sound_write], Cost.new.steady_cost(prog)
  end

  # Sound counts alongside drawing on the same frame, against the same budget.
  def test_music_counts_alongside_drawing
    prog = music_game(10, draw: clear_screen(:black)) # a whole-screen clear + the song
    near dma_blob(240 * 160) + song_frame_cost(10), Cost.new.steady_cost(prog)
  end

  # The song shows up in the drill-down tree with its cost and note count.
  def test_the_song_appears_in_the_cost_tree
    play = Cost.new.analyze(music_game(10)).find { |node| node[:op] == :play_song }
    refute_nil play, "play_song should appear as a costed leaf"
    near song_frame_cost(10), play[:cost]
    assert_match(/10 notes/, play[:label])
  end

  # rom.explain's JSON carries a per-song breakdown, judged against the music budget.
  def test_json_carries_the_song_breakdown
    song = Cost.new.as_json(music_game(10))[:songs].first
    assert_equal :theme, song[:name]
    assert_equal 10, song[:notes]
    assert_equal Cost::MUSIC_STEADY_BUDGET, song[:budget]
    refute song[:over], "a 10-note song is well under the music budget"
  end

  # A tune long enough that its per-frame note-check chain is heavy on its own is
  # flagged over the music budget; an ordinary short one is not.
  def test_a_long_song_is_over_the_music_budget
    long = Cost.new.song_verdicts(music_game(300)).first # 6 + 300*3 = 906 > 800
    assert long[:over]

    short = Cost.new.song_verdicts(music_game(50)).first # 6 + 50*3 = 156
    refute short[:over]
  end
end

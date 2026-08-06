# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Shaping the cost tree for a reader (lib/ruby_gba/ir/cost_model/tree.rb): the
# analyze tree itself, then the folding, grouping and pruning that tame it.
class TestCostTree < CostModelTest
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
    near plot_rect(10, 10), tree[0][:cost]
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

  # A repeated multi-op block folds into one group, shown once, with its ×N count
  # and the whole run's rolled-up cost — the wall an unrolled per-thing check (brick
  # collision) turns into.
  def test_collapse_repeats_folds_a_repeated_block
    block = [
      { op: :set, label: "set", cost: 1, children: [] },
      { op: :beep, label: "beep :brick", cost: 1, children: [] },
    ]
    tree = block * 3 # the same 2-op block, three times in a row
    folded = Cost.new.collapse_repeats(tree)

    assert_equal 1, folded.length
    assert_equal :group, folded[0][:op]
    assert_equal 3, folded[0][:count]
    assert_equal "(repeated ×3)", folded[0][:label]
    assert_equal 6, folded[0][:cost] # 3 blocks × 2 ops × cost 1
    assert_equal %i[set beep], folded[0][:children].map { |n| n[:op] } # the block, once
  end

  # A sequence that doesn't repeat is left exactly as it was.
  def test_collapse_repeats_leaves_a_non_repeating_sequence
    tree = [
      { op: :set, label: "set", cost: 1, children: [] },
      { op: :add, label: "add", cost: 1, children: [] },
    ]
    assert_equal tree, Cost.new.collapse_repeats(tree)
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

  # The mixer's per-frame cost shows up as a leaf in the SOUND section — rolled up
  # with everything else, not a bolt-on line.
  def test_the_mixer_shows_up_in_the_sound_section
    sound = Cost.new.category_tree(sample_game).find { |c| c[:category] == :sound }
    refute_nil sound, "a sample-playing program has a sound section"
    assert sound[:children].any? { |n| n[:op] == :mixer }, "the mixer is a leaf in the sound section"
    assert_operator sound[:cost], :>, 0
  end
end

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
    assert_equal %i[fill_rect draw_rect_at], tree.map(&:op)
    near plot_rect(10, 10), tree[0].cost
    near dma_rows_placed(8, 8), tree[1].cost
  end

  # A repeat node carries its multiplied cost and keeps its per-iteration body — which
  # leads with what one pass round the loop costs, before the body does anything.
  def test_analyze_repeat_node_multiplies_and_keeps_its_body
    prog = program do
      screen :bitmap
      repeat(3) { |_i| draw_rect_at 0, 0, 8, 8, :green } # 3 * (64 + one pass)
      halt
    end
    rep = Cost.new.analyze(prog).find { |n| n.op == :repeat }
    near loop_cost(3, dma_rows_placed(8, 8)), rep.cost
    assert_equal "the loop itself", rep.children.first.label
    near dma_rows_placed(8, 8), rep.children.last.cost # per-iteration
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
    cnode = Cost.new.analyze(prog).find { |n| n.op == :case }
    near dma_rows_placed(10, 10), cnode.cost
    near dma_rows_placed(2, 2), cnode.children[0].cost
    near dma_rows_placed(10, 10), cnode.children[1].cost
  end

  # --- scoping transforms (data in, data out — the guts of the drill-down view) ---

  # Runs of identical sibling leaves fold into one "op ×N" node, cost summed.
  def test_aggregate_folds_identical_sibling_leaves
    tree = [
      entry(op: :fill_rect, label: "fill_rect 4x4", cost: 16, w: 4, h: 4),
      entry(op: :fill_rect, label: "fill_rect 4x4", cost: 16, w: 4, h: 4),
      entry(op: :pixel, label: "pixel", cost: 1),
    ]
    agg = Cost.new.aggregate(tree)
    assert_equal 2, agg.length
    assert_equal 32, agg[0].cost
    assert_equal 2, agg[0].count
    assert_equal "fill_rect ×2", agg[0].label
  end

  # Different sizes stay distinct — a stripe isn't folded into a corner square.
  def test_aggregate_keeps_different_sizes_distinct
    tree = [
      entry(op: :fill_rect, label: "big", cost: 100, w: 10, h: 10),
      entry(op: :fill_rect, label: "small", cost: 16, w: 4, h: 4),
    ]
    assert_equal 2, Cost.new.aggregate(tree).length
  end

  # A subtree deeper than max_depth collapses to a leaf that remembers what it hid,
  # with its rolled-up cost intact.
  def test_prune_collapses_subtrees_below_max_depth
    tree = [entry(op: :call, label: "call :x", cost: 200, children: [
      entry(op: :draw_rect_at, label: "d", cost: 100),
      entry(op: :draw_rect_at, label: "d", cost: 100),
    ])]
    pruned = Cost.new.prune(tree, 0)
    assert_empty pruned[0].children
    assert_equal 2, pruned[0].collapsed
    assert_equal 200, pruned[0].cost
  end

  # A repeated multi-op block folds into one group, shown once, with its ×N count
  # and the whole run's rolled-up cost — the wall an unrolled per-thing check (brick
  # collision) turns into.
  def test_collapse_repeats_folds_a_repeated_block
    block = [
      entry(op: :set, label: "set", cost: 1),
      entry(op: :beep, label: "beep :brick", cost: 1),
    ]
    tree = block * 3 # the same 2-op block, three times in a row
    folded = Cost.new.collapse_repeats(tree)

    assert_equal 1, folded.length
    assert_equal :group, folded[0].op
    assert_equal 3, folded[0].count
    assert_equal "(repeated ×3)", folded[0].label
    assert_equal 6, folded[0].cost # 3 blocks × 2 ops × cost 1
    assert_equal %i[set beep], folded[0].children.map(&:op) # the block, once
  end

  # A sequence that doesn't repeat is left exactly as it was.
  def test_collapse_repeats_leaves_a_non_repeating_sequence
    tree = [
      entry(op: :set, label: "set", cost: 1),
      entry(op: :add, label: "add", cost: 1),
    ]
    assert_equal tree, Cost.new.collapse_repeats(tree)
  end

  # The flat "profiler" view ranks op kinds by total cost.
  def test_hot_ops_ranks_op_kinds_by_total_cost
    tree = [
      entry(op: :clear_screen, label: "c", cost: 38_400),
      entry(op: :draw_rect_at, label: "d", cost: 64),
      entry(op: :draw_rect_at, label: "d", cost: 64),
    ]
    hot = Cost.new.hot_ops(tree, 5)
    assert_equal :clear_screen, hot[0].op
    assert_equal 128, hot[1].cost # the two draw_rect_ats, summed
    assert_equal 2, hot[1].count
  end

  # An op inside a loop is counted once per pass. The tree shows a loop body once and
  # multiplies at the loop line, so reading the leaves flat has to put the multiplier
  # back — otherwise the one view meant to say where the time goes reports a program's
  # hottest work, which is nearly always in a loop, at a fraction of what it costs.
  def test_hot_ops_counts_a_loop_body_once_per_pass
    tree = [entry(op: :repeat, label: "repeat x30", cost: 120, factor: 30, children: [
      entry(op: :pixel, label: "pixel", cost: 4),
    ])]
    hot = Cost.new.hot_ops(tree, 5)
    assert_equal 120, hot[0].cost, "30 passes over a 4-scanline body"
    assert_equal 30, hot[0].count, "and it runs 30 times a frame"
  end

  # Only one scene runs a frame and the estimate charges the heaviest, so a lighter
  # scene adds nothing here — summing them all would report work that never shares a
  # frame.
  def test_hot_ops_charges_only_the_heaviest_scene
    prog = program do
      screen :bitmap
      var :state, 0
      scene(:light) { fill_rect 0, 0, 2, 2, :red }
      scene(:heavy) { fill_rect 0, 0, 10, 10, :red }
      game_loop do
        case_var(:state) do
          when_val 0, :light
          when_val 1, :heavy
        end
      end
    end
    cost = Cost.new
    hot = cost.hot_ops(cost.category_tree(prog), 5).find { |h| h.op == :fill_rect }
    near plot_rect(10, 10), hot.cost
    assert_equal 1, hot.count, "one fill a frame, not one per scene"
  end

  # A fold shows what the op is CALLED, so a run of divides reads as divides. An op
  # whose kind is machinery rather than English carries its own name (see Tree#name_of).
  def test_aggregate_folds_a_named_op_under_its_name
    divide = entry(op: :divide_worked_out, name: "divide (worked out)",
                   label: "divide (worked out)", cost: 1)
    assert_equal "divide (worked out) ×2", Cost.new.aggregate([divide, divide])[0].label
  end

  # The mixer's per-frame cost shows up as a leaf in the SOUND section — rolled up
  # with everything else, not a bolt-on line.
  def test_the_mixer_shows_up_in_the_sound_section
    sound = Cost.new.category_tree(sample_game).find { |c| c.category == :sound }
    refute_nil sound, "a sample-playing program has a sound section"
    assert sound.children.any? { |n| n.op == :mixer }, "the mixer is a leaf in the sound section"
    assert_operator sound.cost, :>, 0
  end

  # --- the sections: what KIND of work, which is a fact about the statement ---

  # A routine that draws AND thinks appears in both sections, each carrying its own
  # share. It used to go wholly into whichever section held most of its cost, so a
  # routine's whole cost sat under one heading and the other read as nearly nothing.
  def test_a_routine_that_draws_and_thinks_is_in_both_sections
    sections = Cost.new.category_tree(mixed_routine_game).to_h { |c| [c.category, c] }
    assert_equal %i[drawing logic], sections.keys.sort
    calls = sections.transform_values { |section| find_by_title(section.children, "call :mixed") }
    calls.each do |cat, call|
      refute_nil call, "the #{cat} section reaches the routine"
      assert_operator call.cost, :>, 0
    end
    assert(calls[:drawing].children.none? { |kid| kid.op == :add },
           "the routine's counting is not filed under drawing")
    assert(calls[:logic].children.none? { |kid| kid.op == :dma_fill_rect },
           "the routine's drawing is not filed under logic")
  end

  # THE REGRESSION. Keeping a routine in the console's quick memory makes its
  # instructions cheaper, which is a fact about the cost and not about the kind of work.
  # When a section was decided by majority, that discount was enough to flip a routine
  # from `logic` to `drawing` on wolf3d, moving thousands of scanlines between the two
  # headline lines on a one-word change. So: both sections must fall, and neither may
  # take the other's work.
  def test_keeping_a_routine_in_quick_memory_moves_no_work_between_the_sections
    prog = mixed_routine_game
    slow = Cost.new.category_tree(prog)
    fast = Cost.new(fast_routines: [:mixed]).category_tree(prog)

    # The exact property, said without a number: every statement is in the same section
    # either way. Costs are free to fall — that is what the quick memory is for.
    assert_equal filed_under(slow), filed_under(fast)
    slow.zip(fast) do |before, after|
      assert_operator after.cost, :<, before.cost, "#{before.category} runs faster from the quick memory"
    end
  end

  # Every leaf lands in exactly one section, so the three of them still add up to the
  # frame — and so does every container inside them. This is the guard on Tree.recost,
  # which repeats what the walker does when it works a container's cost out from its
  # children: a fourth kind of container over there fails here rather than quietly
  # mis-adding.
  def test_the_sections_add_back_up_to_the_tree_they_came_from
    [mixed_routine_game, scene_game, loop_game, sample_game].each do |prog|
      cost = Cost.new
      whole = cost.analyze(prog)
      sections = cost.category_tree(prog)
      near whole.sum(&:cost), sections.sum(&:cost) - standing(cost, prog)
      whole.each_with_index do |node, i|
        parts = sections.filter_map { |s| find_by_title(s.children, node.title) }
        near node.cost, parts.sum(&:cost), "statement #{i} (#{node.title}) adds back up"
      end
    end
  end

  private

  # Which section each statement was filed under, by name — what must not move.
  def filed_under(sections)
    sections.to_h { |section| [section.category, leaves([section]).map(&:title).tally] }
  end

  # One routine that both draws and counts, called from the frame. The transfers gain
  # nothing from the quick memory and the counting gains the lot, which is what makes
  # this the shape that used to flip.
  def mixed_routine_game
    program do
      screen :bitmap
      x = var :x, 0
      func(:mixed) do
        6.times { |i| dma_fill_rect 0, i * 10, 120, 10, :red }
        200.times { x.add 1 }
      end
      game_loop { call :mixed }
    end
  end

  # A game with two scenes, so the tree carries a case_var — the one container whose
  # cost is not the sum of its children (only the dearest scene is charged).
  def scene_game
    program do
      screen :bitmap
      var :state, 0
      x = var :x, 0
      scene(:light) { fill_rect 0, 0, 2, 2, :red }
      scene(:heavy) do
        fill_rect 0, 0, 10, 10, :red
        20.times { x.add 1 }
      end
      game_loop do
        case_var(:state) do
          when_val 0, :light
          when_val 1, :heavy
        end
      end
    end
  end

  # A loop that both draws and counts. A loop is the container that bakes its passes
  # into its own cost, so a projection that forgot them would come back eight times
  # light here.
  def loop_game
    program do
      screen :bitmap
      x = var :x, 0
      game_loop do
        repeat(8) do |i|
          draw_rect_at 0, i, 40, 1, :red
          4.times { x.add 1 }
        end
      end
    end
  end

  # The tree carries the standing costs (the mixer, a bend, a timer's ticks) that the
  # op tree has no statement for, so they have to come off before the two are compared.
  def standing(cost, program) = cost.as_json(program)[:frame_cost] - cost.analyze(program).sum(&:cost)

  # The first node with this title anywhere under +nodes+ — a section's copy of one of
  # the frame's statements, however deep the per-file grouping put it.
  def find_by_title(nodes, title)
    nodes.each do |node|
      return node if node.title == title

      found = find_by_title(node.children, title)
      return found if found
    end
    nil
  end
end

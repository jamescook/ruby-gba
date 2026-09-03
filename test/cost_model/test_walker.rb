# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# The walk itself (lib/ruby_gba/ir/cost_model/walker.rb): how many times a frame pays
# for something, and the position state that answers "what's true right now" while
# it's walking (current screen mode, area height, whether the code being priced runs
# from fast memory). Exercised directly, against a bare Walker instance, independent
# of the black-box CostModel tests.
class TestWalker < CostModelTest
  Walker = RubyGBA::IR::CostModel::Walker
  Catalogue = RubyGBA::IR::CostModel::Catalogue
  Pricing = RubyGBA::IR::CostModel::Pricing
  Tree = RubyGBA::IR::CostModel::Tree

  def empty_catalogue
    Catalogue.new(modes: nil, funcs: {}, capacities: {}, declared: {}, list_lengths: {},
                  table_lengths: {}, songs: {}, bitmaps: {}, objects: {}, backing: {},
                  sees_through: false)
  end

  # A walker wired the way Rollup#index wires the real one — its own Pricing (for
  # #tear_free?/#current_mode, which #own_op_cost asks of it) and Tree (for #label_of,
  # which every priced leaf asks for) — minus Verdicts, which none of these tests'
  # programs exercise (see Tree#label_of: only :play_song's leaf needs it).
  def walker(catalogue: empty_catalogue)
    w = Walker.new(catalogue: catalogue, weights: WEIGHTS, fast_routines: [], fast_frame: false,
                   fast_interrupts: false, loop_shapes: {})
    pricing = Pricing.new(weights: WEIGHTS, catalogue: catalogue, walker: w, palette_entries: {})
    w.pricing = pricing
    w.tree = Tree.new(catalogue: catalogue, pricing: pricing, walker: w, verdicts: nil)
    w
  end

  def test_current_mode_falls_back_to_direct_with_no_build_behind_it
    w = walker
    assert_equal RubyGBA::IR::Modes::DIRECT, w.current_mode
    refute w.tear_free?
  end

  def test_in_code_toggles_in_fast_code_for_the_block_and_restores_it_after
    w = walker
    refute w.in_fast_code?

    seen = nil
    w.in_code(fast: true) { seen = w.in_fast_code? }

    assert seen, "in_fast_code? was true during the block"
    refute w.in_fast_code?, "and false again once it ended"
  end

  def test_within_area_holds_the_draw_height_for_the_block_and_restores_it_after
    w = walker
    assert_nil w.draw_height, "no area, no height"

    node = Struct.new(:h).new(40)
    seen = nil
    w.within_area(node) { seen = w.draw_height }

    assert_equal 40, seen
    assert_nil w.draw_height, "back outside the area"
  end

  def test_at_full_capacity_toggles_selectivity_for_the_block_and_restores_it_after
    w = walker
    of_node = Struct.new(:kind, :of, :usually).new(:if, 8, nil)

    outside = w.selectivity(of_node)
    inside = nil
    w.at_full_capacity { inside = w.selectivity(of_node) }

    assert_equal 1, inside, "every slot counts as live at full capacity"
    refute_equal 1, outside, "an ordinary walk shares it out instead (a guess, here: a quarter)"
  end

  # This is the regression the Catalogue/Walker split had to not introduce: #index used
  # to be called AGAIN mid-walk (steady_cost, called from inside an at_full_capacity
  # block) and never reset @at_full_capacity when it did — see Rollup#index's comment.
  # Reindexing a walker has to keep that promise.
  def test_reindex_keeps_the_walks_own_toggles_but_replaces_the_catalogue
    w = walker
    w.in_code(fast: true) do
      w.reindex(empty_catalogue)
      assert w.in_fast_code?, "reindexing mid-block must not reset a toggle the block set"
    end
    refute w.in_fast_code?
  end

  def test_reindex_resets_the_call_stack
    prog = program do
      screen :bitmap
      func(:helper) { fill_rect 0, 0, 4, 4, :red }
      call :helper
      halt
    end
    catalogue = Catalogue.build(prog)
    w = walker(catalogue: catalogue)

    refute_empty w.func_children(:helper), "nothing on the stack yet, so :helper prices normally"

    # #analyze with a focus pushes the routine onto the walk's call stack and never pops
    # it — that's the one caller (rom.explain's drill-down) that leaves it dirty on purpose.
    w.analyze(prog, focus: :helper)
    assert_empty w.func_children(:helper), "the cycle guard trips: :helper is still on the stack"

    w.reindex(catalogue)
    refute_empty w.func_children(:helper), "reindex cleared the stack, so :helper is reachable again"
  end
end

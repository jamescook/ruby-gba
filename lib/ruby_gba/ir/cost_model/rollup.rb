# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # How often a frame pays for each op, and what that adds up to — the question
      # {Walker} answers. This file settles what a fresh answer needs (a {Catalogue}
      # and a {Walker} built from it, in #index) and forwards every other call to the
      # walker it built — so nothing outside cost_model/, and nothing in the other
      # cost_model files still mixed into this same instance, had to change to keep
      # reaching Rollup's old public methods by name.
      #
      # +@stack+, +@draw_height+, +@in_fast_code+, +@at_full_capacity+ used to live
      # here as ivars any included module could read directly; they now live inside
      # {Walker} and are reached only through its methods (see Walker's own comment
      # for why, and for the shape of the walk itself).
      module Rollup
        # The draw work of one frame as a structured cost tree: an array of nodes
        # { op:, label:, cost:, children: }. It's the game loop's body if there is
        # one, otherwise the one-time boot draws of a static program. Costs roll up:
        # a container's cost is the sum of its children (a repeat multiplies, a
        # case_var takes its worst branch).
        def analyze(program, focus: nil)
          index(program)
          @walker.analyze(program, focus: focus)
        end

        # The total draw cost of one frame — the roll-up of #analyze. This is the
        # *full* cost of everything on the frame, ignoring how often it runs.
        def frame_cost(program)
          index(program)
          @walker.frame_cost(program)
        end

        # The whole per-frame cost that actually recurs *every* frame (drawing, logic,
        # and sound) — the 60fps load. Cost hints scale work down: an every(k) body
        # counts 1/k, a transition-guarded body counts 0, and so on. Untagged work
        # weighs 1, so a program with no hints has steady_cost == frame_cost. For the
        # tear risk use #steady_tear_cost.
        def steady_cost(program)
          index(program)
          @walker.steady_cost(program)
        end

        # WHAT RACES THE SAFE WINDOW, which is the tear risk: everything the frame does
        # from the moment the screen is ready up to and including the LAST thing it
        # draws (see {Walker}#steady_tear_cost for the full account of why).
        def steady_tear_cost(program)
          index(program)
          @walker.steady_tear_cost(program)
        end

        def draws?(node, seen = []) = @walker.draws?(node, seen)
        def func_draws?(name, seen) = @walker.func_draws?(name, seen)

        # The statements that make up a frame — a game loop's body, or a static
        # program's top-level draws (funcs excluded; they're counted where called).
        def steady_statements(program)
          index(program)
          @walker.steady_statements(program)
        end

        # What one pass through a named routine costs — its own statements, its loops
        # multiplied out, and the routines it calls. This is what a backend ranks by when
        # it decides which routines are worth keeping in faster memory (see
        # Backends::GBA::Placement).
        def func_frame_cost(program, name)
          index(program)
          @walker.func_frame_cost(name)
        end

        private

        # Everything a price needs to know before it can be asked — which routine draws
        # where, every declaration in the program (see {Catalogue}) — and a walker to
        # answer everything else. Every analysis starts here, so the catalogue and the
        # walk's call stack reset with it.
        #
        # A walker already exists when this runs a SECOND time nested inside a first
        # (steady_cost called from inside an at_full_capacity block, to name the one
        # caller that does) — and then it is reused rather than replaced, so the outer
        # call's toggles (at_full_capacity, in_fast_code, the current area's height)
        # survive the re-index instead of silently resetting (see Walker#reindex).
        def index(program)
          @unpriced = [] # kinds seen with no estimate — reset each analysis (see #unpriced_kinds)
          @catalogue = Catalogue.build(program)
          if @walker
            @walker.reindex(@catalogue)
          else
            @walker = Walker.new(catalogue: @catalogue, pricing: self, weights: @weights,
                                 fast_routines: @fast_routines, fast_frame: @fast_frame,
                                 fast_interrupts: @fast_interrupts, loop_shapes: @loop_shapes)
          end
        end

        def steady(node, worst: false) = @walker.steady(node, worst: worst)
        def steady_func(name, worst: false) = @walker.steady_func(name, worst: worst)
        def in_fast_memory(name, &block) = @walker.in_fast_memory(name, &block)
        def in_fast_frame(&block) = @walker.in_fast_frame(&block)
        def in_fast_interrupts(&block) = @walker.in_fast_interrupts(&block)
        def in_code(fast:, &block) = @walker.in_code(fast: fast, &block)
        def within_area(node, &block) = @walker.within_area(node, &block)
        def branch_cost(node, worst:) = @walker.branch_cost(node, worst: worst)
        def known_share?(node) = @walker.known_share?(node)
        def selectivity(node) = @walker.selectivity(node)
        def live_share(node) = @walker.live_share(node)
        def unsaid_share(slots) = @walker.unsaid_share(slots)

        # What every per-pixel collision test in a frame costs if they all land at once —
        # the part of the worst case the recurring load leaves out, so the estimate can say
        # so out loud rather than just showing a bigger number further down.
        def collision_worst_case(program) = @walker.collision_worst_case(program)

        # The screen the op being priced draws on (see {Walker}#current_mode).
        def current_mode = @walker.current_mode
        def tear_free? = @walker.tear_free?

        def build(node) = @walker.build(node)
        def condition_leaf(cond) = @walker.condition_leaf(cond)
        def build_leaf(node) = @walker.build_leaf(node)
        def statement_leaf(node, cost) = @walker.statement_leaf(node, cost)

        def arithmetic_leaves(value, category:, source:, out: [])
          @walker.arithmetic_leaves(value, category: category, source: source, out: out)
        end

        def build_case(node) = @walker.build_case(node)
        def build_call(node) = @walker.build_call(node)
        def build_repeat(node) = @walker.build_repeat(node)
        def loop_overhead_leaf(node, factor) = @walker.loop_overhead_leaf(node, factor)
        def loop_overhead_name(node) = @walker.loop_overhead_name(node)
        def loop_overhead_label(node) = @walker.loop_overhead_label(node)
        def loop_shape(node) = @walker.loop_shape(node)
        def held_loop?(node) = @walker.held_loop?(node)
        def loop_pass_cost(node) = @walker.loop_pass_cost(node)
        def spill_cost(node) = @walker.spill_cost(node)
        def loop_start_cost(node) = @walker.loop_start_cost(node)
        def build_timer(node, label) = @walker.build_timer(node, label)
        def func_children(name) = @walker.func_children(name)
        def sum(nodes) = @walker.sum(nodes)
        def repeat_factor(node, typical: false) = @walker.repeat_factor(node, typical: typical)
        def worked_out_passes(node, typical:) = @walker.worked_out_passes(node, typical: typical)
        def counts_frames?(count) = @walker.counts_frames?(count)
        def frames_answered_for(typical:) = @walker.frames_answered_for(typical: typical)
        def at_full_capacity(&block) = @walker.at_full_capacity(&block)
        def early_exit_passes(node, typical:) = @walker.early_exit_passes(node, typical: typical)
        def stops_early?(node) = @walker.stops_early?(node)
        def list_length(name) = @walker.list_length(name)

        def sees_through_a_layer? = @catalogue.sees_through_a_layer?
      end
    end
  end
end

# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # How often a frame pays for each op, and what that adds up to — the question
      # {Walker} answers. This file settles what a fresh answer needs (a {Catalogue}
      # and a {Walker} built from it, in #index) and hands every other call straight
      # to the walker it built. Reopens {CostModel} itself rather than mixing in a
      # module — there is only one instance these methods ever run on, so a separate
      # module bought no adapter and no seam, only an extra name to look through.
      #
      # +@stack+, +@draw_height+, +@in_fast_code+, +@at_full_capacity+ live inside
      # {Walker}, reached only through its methods — not here, and not as ivars any
      # other file can read directly (see Walker's own comment for why, and for the
      # shape of the walk itself).

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
        @catalogue = catalogue_for(program)
        if @walker
          @walker.reindex(@catalogue)
        else
          @walker = Walker.new(catalogue: @catalogue, weights: @weights, fast_routines: @fast_routines,
                               fast_frame: @fast_frame, fast_interrupts: @fast_interrupts,
                               loop_shapes: @loop_shapes)
        end

        # Pricing, Verdicts, Tree, and Domains are all rebuilt fresh here, every time —
        # unlike the walker, none of them carry state that a nested re-index (steady_cost
        # called from inside an at_full_capacity block) could drop. Two pairs need each
        # other both ways (Walker asks Pricing to price an op; Pricing asks Walker where
        # the walk is now — and Tree asks Verdicts for the standing costs; Verdicts asks
        # Tree for the estimate #residual_note checks a measurement against), so each pair
        # is built one side first and wired back after (see Walker#pricing=/#tree= and
        # Verdicts#tree=).
        @pricing = Pricing.new(weights: @weights, catalogue: @catalogue, walker: @walker,
                               palette_entries: @palette_entries, column_stretches: @column_stretches,
                               emitted: @emitted)
        @walker.pricing = @pricing
        @verdicts = Verdicts.new(weights: @weights, catalogue: @catalogue, walker: @walker,
                                 pricing: @pricing, fast_frame: @fast_frame,
                                 fast_interrupts: @fast_interrupts)
        @tree = Tree.new(catalogue: @catalogue, pricing: @pricing, walker: @walker, verdicts: @verdicts)
        @walker.tree = @tree
        @verdicts.tree = @tree
        @domains = Domains.new(weights: @weights, pricing: @pricing, verdicts: @verdicts)
      end

      def catalogue_for(program) = Catalogue.for(program)

      # What every per-pixel collision test in a frame costs if they all land at once —
      # the part of the worst case the recurring load leaves out, so the estimate can say
      # so out loud rather than just showing a bigger number further down.
      def collision_worst_case(program) = @walker.collision_worst_case(program)
    end
  end
end

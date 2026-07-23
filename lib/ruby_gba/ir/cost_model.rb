# frozen_string_literal: true

module RubyGBA
  module IR
    # Estimates how much *drawing* a program does — per frame for a game loop, or
    # once at boot for a static program. It's the engine behind the render-budget
    # guardrail and `rom.explain`: a program that draws more each frame than the
    # console can finish before the screen refreshes will tear, and this is how we
    # spot that before it ever runs on hardware.
    #
    # Costs are in "write-units" — roughly one write to the screen. The weights are
    # rough, tunable placeholders for now (real values come from measuring on the
    # console); a game dev can override any of them, e.g. to weight an op up to
    # discourage it. What the model gets exactly right is the *shape* of the work:
    # a loop's body counts once per iteration, a list-driven loop counts up to the
    # list's capacity (the worst it can reach), and a scene dispatch (case_var)
    # costs its heaviest branch, since only one branch runs per frame.
    #
    # Selectivity — that `every(6)` only draws one frame in six, that a
    # `draw_number` column draws one of ten glyphs — is a later layer that reads
    # semantic tags off the IR; today every branch is counted at full weight.
    class CostModel
      SCREEN_W = 240
      SCREEN_H = 160

      # Illustrative per-frame drawing budget (write-units): roughly what the
      # console can draw in the safe window each frame before the picture tears.
      # A rough placeholder until calibrated on hardware.
      VBLANK_BUDGET = 80_000

      # Illustrative defaults (write-units). Override per-call: CostModel.new(pixel: 2).
      DEFAULT_WEIGHTS = {
        pixel: 1,   # one filled/plotted pixel
        glyph: 35,  # one 5x7 font glyph (~35 lit pixels)
      }.freeze

      def initialize(**weights)
        @weights = DEFAULT_WEIGHTS.merge(weights)
      end

      # Print a short, human draw-cost estimate for +program+ to +out+: the
      # per-frame cost against the frame budget for a game loop, or the one-time
      # boot cost for a static program. (The full drill-down tree and JSON come
      # later; this is the at-a-glance summary.)
      def report(program, out: $stdout)
        total = frame_cost(program)
        looping = program.children.any? { |node| node.kind == :loop }
        out.puts "draw-cost estimate (rough, illustrative weights):"
        if looping
          over = total > VBLANK_BUDGET
          out.puts "  per frame ~ #{total} write-units   (budget ~ #{VBLANK_BUDGET})   " \
                   "#{over ? '! over budget — the screen may tear as things grow' : 'ok — fits the frame'}"
        else
          out.puts "  boot draw ~ #{total} write-units   (no game loop — drawn once, then halts)   ok"
        end
      end

      # The draw cost of one frame: the game loop's body if there is one, otherwise
      # the one-time boot draws of a static program.
      def frame_cost(program)
        index(program)
        @stack = []
        loop_node = program.children.find { |n| n.kind == :loop }
        statements = loop_node ? loop_node.children : program.children.reject { |n| n.kind == :func }
        statements.sum { |node| cost(node) }
      end

      private

      # Catalogue the funcs (so a `call`/`case` can be costed) and the list
      # capacities (so a repeat over a list can be bounded).
      def index(program)
        @funcs = {}
        @capacities = {}
        program.walk do |node|
          @funcs[node[:name]] = node if node.kind == :func
          @capacities[node[:name]] = node[:capacity] if node.kind == :list_new
        end
      end

      def cost(node)
        case node.kind
        when :program, :loop, :else then node.children.sum { |child| cost(child) }
        when :if   then node.children.sum { |child| cost(child) } + (node[:else] ? cost(node[:else]) : 0)
        when :repeat then repeat_factor(node) * node.children.sum { |child| cost(child) }
        when :case then node[:clauses].map { |_value, target| body_cost(target) }.max || 0
        when :call then body_cost(node[:target])
        when :func then 0 # a definition: it costs only where it's called
        else op_cost(node)
        end
      end

      # The cost of a named func's body, guarding against a call cycle.
      def body_cost(name)
        return 0 if @stack.include?(name)
        func = @funcs[name] or return 0
        @stack.push(name)
        total = func.children.sum { |child| cost(child) }
        @stack.pop
        total
      end

      # How many times a repeat runs its body: a literal count exactly; a list's
      # length up to the list's capacity (the most it can hold). An unknown count
      # (a plain variable) counts as zero for now — a later pass flags it unbounded.
      def repeat_factor(node)
        count = node[:count]
        return count[:value] if count.is_a?(Node) && count.kind == :int
        return @capacities.fetch(count[:name], 0) if count.is_a?(Node) && count.kind == :list_len

        0
      end

      def op_cost(node)
        px = @weights[:pixel]
        case node.kind
        when :pixel then px
        when :fill_rect, :dma_fill_rect, :draw_rect_at then node[:w] * node[:h] * px
        when :clear_screen then SCREEN_W * SCREEN_H * px
        when :draw_text then node[:text].to_s.length * @weights[:glyph] * px
        else 0 # non-draw ops: no draw cost
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"

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
    # #analyze returns the work as a structured tree (op, label, cost, children) —
    # the shape rom.explain renders for humans and dumps as JSON for tests.
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

      # The draw work of one frame as a structured cost tree: an array of nodes
      # { op:, label:, cost:, children: }. It's the game loop's body if there is
      # one, otherwise the one-time boot draws of a static program. Costs roll up:
      # a container's cost is the sum of its children (a repeat multiplies, a
      # case_var takes its worst branch).
      def analyze(program)
        index(program)
        @stack = []
        loop_node = program.children.find { |node| node.kind == :loop }
        statements = loop_node ? loop_node.children : program.children.reject { |node| node.kind == :func }
        statements.flat_map { |node| build(node) }
      end

      # The total draw cost of one frame — the roll-up of #analyze.
      def frame_cost(program)
        analyze(program).sum { |node| node[:cost] }
      end

      # Whether a program has a game loop (its cost recurs every frame) or is a
      # one-shot static draw.
      def looping?(program)
        program.children.any? { |node| node.kind == :loop }
      end

      # Print a short, human draw-cost estimate to +out+: the per-frame cost against
      # the frame budget for a game loop, or the one-time boot cost otherwise. (The
      # full drill-down tree comes later; this is the at-a-glance summary.)
      def report(program, out: $stdout)
        total = frame_cost(program)
        out.puts "draw-cost estimate (rough, illustrative weights):"
        if looping?(program)
          over = total > VBLANK_BUDGET
          out.puts "  per frame ~ #{total} write-units   (budget ~ #{VBLANK_BUDGET})   " \
                   "#{over ? '! over budget — the screen may tear as things grow' : 'ok — fits the frame'}"
        else
          out.puts "  boot draw ~ #{total} write-units   (no game loop — drawn once, then halts)   ok"
        end
      end

      # The analysis as a plain Hash, ready to serialize (rom.explain format: :json).
      def as_json(program)
        {
          frame_cost: frame_cost(program),
          budget: VBLANK_BUDGET,
          looping: looping?(program),
          tree: analyze(program),
        }
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

      # Build the cost tree for a node — an array (if/else/program are transparent
      # and splice their children; a non-draw leaf contributes nothing).
      def build(node)
        case node.kind
        when :program, :loop then node.children.flat_map { |child| build(child) }
        when :if then (node.children + [node[:else]].compact).flat_map { |child| build(child) }
        when :else then node.children.flat_map { |child| build(child) }
        when :case then [build_case(node)]
        when :call then [build_call(node)]
        when :repeat then [build_repeat(node)]
        when :func then [] # a definition: it costs only where it's called
        else
          c = op_cost(node)
          c.positive? ? [{ op: node.kind, label: label_of(node), cost: c, children: [] }] : []
        end
      end

      # case_var runs one scene per frame, so its cost is the heaviest branch.
      def build_case(node)
        branches = node[:clauses].map do |value, target|
          kids = func_children(target)
          { op: :branch, label: "#{value} -> :#{target}", cost: sum(kids), children: kids }
        end
        { op: :case, label: "case_var :#{node[:var]}", cost: (branches.map { |b| b[:cost] }.max || 0), children: branches }
      end

      # A call is its target func's body, inlined (guarding against a call cycle).
      def build_call(node)
        kids = func_children(node[:target])
        { op: :call, label: "call :#{node[:target]}", cost: sum(kids), children: kids }
      end

      # A repeat runs its body count times, so its cost multiplies.
      def build_repeat(node)
        factor, note = repeat_factor(node)
        kids = node.children.flat_map { |child| build(child) }
        { op: :repeat, label: "repeat #{note}", cost: factor * sum(kids), children: kids }
      end

      def func_children(name)
        return [] if @stack.include?(name)
        func = @funcs[name] or return []
        @stack.push(name)
        kids = func.children.flat_map { |child| build(child) }
        @stack.pop
        kids
      end

      def sum(nodes) = nodes.sum { |node| node[:cost] }

      # How many times a repeat runs, and a human note: a literal count exactly; a
      # list's length up to its capacity (the most it can hold). An unknown count
      # (a plain variable) counts as zero for now — a later pass flags it unbounded.
      def repeat_factor(node)
        count = node[:count]
        return [count[:value], "x#{count[:value]}"] if count.is_a?(Node) && count.kind == :int
        if count.is_a?(Node) && count.kind == :list_len && @capacities[count[:name]]
          cap = @capacities[count[:name]]
          return [cap, "x<=#{cap} (#{count[:name]} capacity)"]
        end
        [0, "x? (unbounded)"]
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

      def label_of(node)
        case node.kind
        when :fill_rect, :dma_fill_rect, :draw_rect_at then "#{node.kind} #{node[:w]}x#{node[:h]}"
        when :draw_text then "draw_text #{node[:text].inspect}"
        else node.kind.to_s
        end
      end
    end
  end
end

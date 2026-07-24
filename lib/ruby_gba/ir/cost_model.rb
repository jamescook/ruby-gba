# frozen_string_literal: true

require "json"

module RubyGBA
  module IR
    # Estimates how much per-frame work a program does — mostly drawing, plus the
    # sound work that shares the same frame — per frame for a game loop, or once at
    # boot for a static program. It's the engine behind the render-budget guardrail
    # and `rom.explain`: a program that does more each frame than the console can
    # finish before the screen refreshes will tear, and this is how we spot that
    # before it ever runs on hardware.
    #
    # Costs are in "write-units" — roughly one write to the screen. Sound is priced
    # in the same unit so it weighs against the same budget: a sound-register write
    # (a beep, powering the hardware on) counts like a screen write, and playing a
    # song costs one frame-counter check per note *every* frame, because the score
    # is unrolled into a comparison per note (see #song_cost). The weights are
    # rough, tunable placeholders (real values come from measuring on the console);
    # a game dev can override any of them, e.g. to weight an op up to discourage it. What the model gets exactly right is the *shape* of the work:
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

      # The budget when the program double-buffers (draws to a hidden page shown
      # all at once). Then drawing isn't confined to the brief safe window — it can
      # use the whole frame — so the budget is much larger (the safe window is only
      # about a third of a frame). And going over means something different: the
      # frame rate drops below 60fps, the picture never tears. A rough placeholder,
      # like VBLANK_BUDGET.
      FRAME_BUDGET = 3 * VBLANK_BUDGET

      # A rough ceiling on how much per-frame work a *single song* should cost on
      # its own. Playing a song re-checks every note against a frame counter on
      # every frame, so a long enough tune becomes real recurring work that has
      # nothing to do with drawing; past this, the music guardrail flags it. A
      # placeholder like the draw budgets, pending hardware calibration.
      MUSIC_STEADY_BUDGET = 800

      # A sound op is a short burst of writes to the sound registers; these are the
      # write counts, so the model can price them in the same write-units as
      # drawing. (Playing a song is priced separately — see #song_cost.)
      ENABLE_WRITES = 3 # power the sound hardware on
      BEEP_WRITES   = 2 # one channel-2 sound effect
      STOP_WRITES   = 2 # silence the music channel
      SONG_TICK     = 6 # per frame: advance the song's frame counter and wrap it at the end

      # Illustrative defaults (write-units). Override per-call: CostModel.new(pixel: 2).
      DEFAULT_WEIGHTS = {
        pixel: 1,       # one filled/plotted pixel
        glyph: 35,      # one 5x7 font glyph (~35 lit pixels)
        sound_write: 1, # one write to a sound register (a beep, powering sound on)
        note_check: 3,  # per song note, the frame-counter check that runs every frame
      }.freeze

      def initialize(**weights)
        @weights = DEFAULT_WEIGHTS.merge(weights)
      end

      # The draw work of one frame as a structured cost tree: an array of nodes
      # { op:, label:, cost:, children: }. It's the game loop's body if there is
      # one, otherwise the one-time boot draws of a static program. Costs roll up:
      # a container's cost is the sum of its children (a repeat multiplies, a
      # case_var takes its worst branch).
      def analyze(program, focus: nil)
        index(program)
        @stack = []
        if focus
          func = @funcs.fetch(focus)
          @stack.push(focus)
          return func.children.flat_map { |node| build(node) }
        end
        loop_node = program.children.find { |node| node.kind == :loop }
        statements = loop_node ? loop_node.children : program.children.reject { |node| node.kind == :func }
        statements.flat_map { |node| build(node) }
      end

      # --- tree transforms (data in, data out; asserted directly, not via text) ---

      # Fold runs of identical sibling leaves (same op + size) into one "op ×N" node,
      # recursing into children. Tames verbose fan-outs (draw_number's 10 glyphs, a
      # row of identical cells) without losing the rolled-up cost.
      def aggregate(nodes)
        nodes.each_with_object([]) do |raw, out|
          node = raw[:children].to_a.empty? ? raw.dup : raw.merge(children: aggregate(raw[:children]))
          prev = out.last
          if node[:children].to_a.empty? && prev && prev[:children].to_a.empty? &&
             prev[:op] == node[:op] && prev[:w] == node[:w] && prev[:h] == node[:h]
            out[-1] = prev.merge(count: (prev[:count] || 1) + 1, cost: prev[:cost] + node[:cost],
                                 label: "#{node[:op]} ×#{(prev[:count] || 1) + 1}")
          else
            out << node
          end
        end
      end

      # Collapse subtrees deeper than +max_depth+ into a leaf that remembers how many
      # ops it hid — the depth limit that keeps a big program's tree readable.
      def prune(nodes, max_depth, depth = 0)
        nodes.map do |node|
          kids = node[:children].to_a
          if kids.any? && depth >= max_depth
            node.merge(children: [], collapsed: leaf_count(node))
          elsif kids.any?
            node.merge(children: prune(kids, max_depth, depth + 1))
          else
            node
          end
        end
      end

      # The +top+ hottest op kinds across the whole tree — the flat "profiler" view.
      def hot_ops(nodes, top = 5)
        all_leaves(nodes).group_by { |n| n[:op] }
                         .map { |op, ns| { op: op, cost: ns.sum { |n| n[:cost] }, count: ns.sum { |n| n[:count] || 1 } } }
                         .sort_by { |h| -h[:cost] }.first(top)
      end

      # The total draw cost of one frame — the roll-up of #analyze. This is the
      # *full* cost of everything on the frame, ignoring how often it runs.
      def frame_cost(program)
        analyze(program).sum { |node| node[:cost] }
      end

      # The cost that actually recurs *every* frame — the tear risk. Cost hints on
      # the IR scale work down: an every(k) body counts 1/k, a transition-guarded
      # body counts 0, and so on (see #tag_multiplier). Untagged work weighs 1, so
      # a program with no hints has steady_cost == frame_cost.
      def steady_cost(program)
        index(program)
        @stack = []
        loop_node = program.children.find { |node| node.kind == :loop }
        statements = loop_node ? loop_node.children : program.children.reject { |node| node.kind == :func }
        statements.sum { |node| steady(node) }.round
      end

      # Whether a program has a game loop (its cost recurs every frame) or is a
      # one-shot static draw.
      def looping?(program)
        program.children.any? { |node| node.kind == :loop }
      end

      # Whether the program opted into double buffering (a `buffered:` display).
      # This decides which budget applies and how going over it reads: a torn
      # picture (single-buffer) versus a dropped frame (double-buffer).
      def buffered?(program)
        program.walk.any? { |node| node.kind == :display && node[:buffered] }
      end

      # The per-frame draw budget that applies to this program: the whole frame
      # when it double-buffers, otherwise just the brief safe window.
      def budget_for(program)
        buffered?(program) ? FRAME_BUDGET : VBLANK_BUDGET
      end

      # The budget a single display mode gets: the whole frame when buffered (it
      # draws to a hidden page shown all at once, so it can't tear), otherwise just
      # the brief safe window before the visible frame starts.
      def mode_budget(mode)
        mode == Modes::BUFFERED ? FRAME_BUDGET : VBLANK_BUDGET
      end

      # Whether the program mixes display modes across its scenes (some direct,
      # some tear-free). When it does, one whole-program budget is meaningless —
      # each scene has to be judged against its own mode's budget (#scene_verdicts).
      def mixed?(program)
        Modes.resolve(program).mixed?
      end

      # Per-scene render verdicts, for a game that switches modes between scenes.
      # Each scene the loop dispatches to gets its own steady per-frame cost judged
      # against its own mode's budget — so a heavy direct-color scene is caught even
      # when another scene is buffered (which would otherwise widen the budget for
      # the whole program and hide it). Each entry:
      #   { name:, mode:, steady_cost:, budget:, over: }
      def scene_verdicts(program)
        return [] unless looping?(program)

        modes = Modes.resolve(program)
        index(program)
        @stack = []
        modes.scene_funcs.map do |name|
          mode = modes.mode_of(name)
          cost = steady_func(name)
          budget = mode_budget(mode)
          { name: Modes.friendly_name(name), mode: mode, steady_cost: cost,
            budget: budget, over: cost > budget }
        end
      end

      # Per-song playback verdicts, for a program that plays music. Playing a song
      # re-checks every note against a frame counter on every frame — the score is
      # unrolled into one comparison per note — so a long tune is real recurring
      # per-frame work on its own, independent of any drawing. Each song the
      # program actually plays gets its per-frame music cost judged against the
      # music budget, so the guardrail can flag a tune long enough to matter. Each
      # entry: { name:, notes:, steady_cost:, budget:, over: }
      def song_verdicts(program)
        index(program)
        names = program.walk.select { |node| node.kind == :play_song }.map { |node| node[:name] }.uniq
        names.filter_map do |name|
          next unless @songs[name]

          cost = song_cost(name)
          { name: name, notes: song_notes(name), steady_cost: cost,
            budget: MUSIC_STEADY_BUDGET, over: cost > MUSIC_STEADY_BUDGET }
        end
      end

      # Print a short, human draw-cost estimate to +out+: the per-frame cost against
      # the frame budget for a game loop, or the one-time boot cost otherwise. (The
      # full drill-down tree comes later; this is the at-a-glance summary.)
      def report(program, out: $stdout)
        out.puts "draw-cost estimate (rough, illustrative weights):"
        verdict_lines(program, out)
      end

      # The drill-down: the verdict, then the (aggregated, depth-limited) cost tree,
      # then the hottest ops. +focus+ roots the tree at a named func; +max_depth+
      # bounds how deep it prints (deeper subtrees collapse to a rollup line).
      def render(program, out: $stdout, max_depth: 3, focus: nil, top: 5)
        tree = aggregate(analyze(program, focus: focus))
        out.puts "draw-cost estimate (rough, illustrative weights):"
        if focus
          out.puts "  func :#{focus} ~ #{tree.sum { |node| node[:cost] }} write-units"
        else
          verdict_lines(program, out)
        end
        render_tree(prune(tree, max_depth), 1, out)
        hot = hot_ops(tree, top)
        out.puts "  hottest: " + hot.map { |h| "#{h[:op]}×#{h[:count]} ~#{h[:cost]}" }.join("  ") unless hot.empty?
      end

      # The analysis as a plain Hash, ready to serialize (rom.explain format: :json).
      def as_json(program)
        {
          frame_cost: frame_cost(program),   # full cost of everything on a frame
          steady_cost: steady_cost(program), # what recurs every frame (the tear risk)
          budget: budget_for(program),       # the applicable budget (wider when buffered)
          buffered: buffered?(program),      # double-buffered? (over budget = a dropped frame, not a tear)
          looping: looping?(program),
          scenes: scene_verdicts(program),   # per-scene cost vs each scene's own budget
          songs: song_verdicts(program),     # per-song music cost vs the music budget
          tree: analyze(program),
        }
      end

      private

      # The selectivity-weighted cost of a subtree: a cost hint scales it (an
      # every(k) body by 1/k, a transition-guarded body to nothing), so what's left
      # is the work that runs every frame. Untagged nodes weigh 1.
      def steady(node)
        tag_multiplier(node) * raw_steady(node)
      end

      def raw_steady(node)
        case node.kind
        when :program, :loop, :else then node.children.sum { |child| steady(child) }
        when :if then node.children.sum { |child| steady(child) } + (node[:else] ? steady(node[:else]) : 0)
        when :repeat then repeat_factor(node).first * node.children.sum { |child| steady(child) }
        # A timed trigger's steady per-frame cost follows from its kind: every(k)
        # runs one frame in k, so its body counts 1/k; after(n) fires once ever, so
        # it adds nothing to the every-frame load.
        when :every then Rational(1, node[:period]) * node.children.sum { |child| steady(child) }
        when :after then 0
        when :case then node[:clauses].map { |_value, target| steady_func(target) }.max || 0
        when :call then steady_func(node[:target])
        when :func then 0
        else op_cost(node)
        end
      end

      def steady_func(name)
        return 0 if @stack.include?(name)
        func = @funcs[name] or return 0
        @stack.push(name)
        total = func.children.sum { |child| steady(child) }
        @stack.pop
        total
      end

      # How much a cost-hinted node contributes to the steady per-frame figure: an
      # every(k) body one frame in k, a transition-guarded body never, a chance(p)
      # body p% of the time. No hint means it always runs (weight 1).
      def tag_multiplier(node)
        tag = node[:cost_tag]
        return 1 unless tag

        case tag[:kind]
        when :glyph_of then Rational(1, tag[:n])
        when :transition then 0
        when :chance then Rational(tag[:percent], 100)
        else 1
        end
      end

      # The verdict, printed to +out+: for a game loop, the STEADY per-frame cost
      # against the budget (the tear risk), plus the heaviest single frame as a
      # one-off spike when it's larger; for a static program, the one-time boot cost.
      # A game that switches modes between scenes is reported scene by scene, since
      # each mode has its own budget.
      def verdict_lines(program, out)
        unless looping?(program)
          out.puts "  boot draw ~ #{frame_cost(program)} write-units   (no game loop — drawn once, then halts)   ok"
          return
        end
        return scene_verdict_lines(program, out) if mixed?(program)

        steady = steady_cost(program)
        full = frame_cost(program)
        budget = budget_for(program)
        over = steady > budget
        # Over budget reads differently depending on the mode: a single-buffered
        # frame tears, a double-buffered one just drops below 60fps.
        over_note = buffered?(program) ? "! over budget — the frame rate drops" : "! over budget — the screen tears"
        out.puts "  steady per frame ~ #{steady} write-units   (budget ~ #{budget})   " \
                 "#{over ? over_note : 'ok — fits the frame'}"
        if full > steady
          out.puts "  heaviest frame   ~ #{full} write-units   " \
                   "(a one-off spike — a transition frame or an every() tick, not the steady load)"
        end
      end

      # One verdict line per scene, each against its own mode's budget — the report
      # for a game that runs some scenes direct-color and others tear-free.
      def scene_verdict_lines(program, out)
        scene_verdicts(program).each do |s|
          mode_label = s[:mode] == Modes::BUFFERED ? "tear-free" : "direct"
          note =
            if s[:over]
              s[:mode] == Modes::BUFFERED ? "! over budget — the frame rate drops" : "! over budget — the screen tears"
            else
              s[:mode] == Modes::BUFFERED ? "ok — fits the frame" : "ok — fits the safe window"
            end
          out.puts "  scene :#{s[:name]} (#{mode_label}) ~ #{s[:steady_cost]} write-units   " \
                   "(budget ~ #{s[:budget]})   #{note}"
        end
      end

      def render_tree(nodes, depth, out)
        nodes.each do |node|
          tag = node[:collapsed] ? "  (+#{node[:collapsed]} ops collapsed)" : ""
          out.puts format("  %-52s ~%d", ("  " * depth) + node[:label] + tag, node[:cost])
          render_tree(node[:children], depth + 1, out) unless node[:children].to_a.empty?
        end
      end

      def leaf_count(node)
        node[:children].to_a.empty? ? 1 : node[:children].sum { |child| leaf_count(child) }
      end

      def all_leaves(nodes)
        nodes.flat_map { |node| node[:children].to_a.empty? ? [node] : all_leaves(node[:children]) }
      end

      # Catalogue the funcs (so a `call`/`case` can be costed), the list capacities
      # (so a repeat over a list can be bounded), and the songs (so a `play_song`
      # can be costed by its note count).
      def index(program)
        @funcs = {}
        @capacities = {}
        @songs = {}
        program.walk do |node|
          @funcs[node[:name]] = node if node.kind == :func
          @capacities[node[:name]] = node[:capacity] if node.kind == :list_new
          @songs[node[:name]] = node if node.kind == :song
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
        when :every then [build_timer(node, "every #{node[:period]}")]
        when :after then [build_timer(node, "after #{node[:frames]}")]
        when :func then [] # a definition: it costs only where it's called
        else build_leaf(node)
        end
      end

      # A drawing op becomes a leaf; anything else costs nothing and is dropped.
      # w/h ride along so aggregation can tell a 33x60 stripe from a 4x4 corner
      # (they're nil for pixel/clear/text, which then all fold together).
      def build_leaf(node)
        c = op_cost(node)
        return [] unless c.positive?

        [{ op: node.kind, label: label_of(node), cost: c, w: node[:w], h: node[:h], children: [] }]
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

      # A timed trigger (every/after) as a labeled container: it carries its body's
      # full cost — the cost of the frame it does fire — so the tree and the
      # heaviest-frame figure read true; the steady discount is applied separately
      # (see #raw_steady). The label names the intent, e.g. "every 30".
      def build_timer(node, label)
        kids = node.children.flat_map { |child| build(child) }
        { op: node.kind, label: label, cost: sum(kids), children: kids }
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
      # (a plain variable) has no provable bound, so it contributes zero to the
      # estimate and is noted as unbounded rather than guessed.
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
        when :play_song then song_cost(node[:name])
        when :beep then BEEP_WRITES * @weights[:sound_write]
        when :enable_sound then ENABLE_WRITES * @weights[:sound_write]
        when :stop_music then STOP_WRITES * @weights[:sound_write]
        else 0 # non-draw, non-sound ops: no per-frame cost
        end
      end

      # The per-frame cost of playing +name+: its score is unrolled into one
      # frame-counter check per note, all re-run every frame, plus a small fixed
      # cost to advance and wrap the counter — so the recurring work grows with the
      # note count. An unknown name costs nothing (the backend reports it).
      def song_cost(name)
        return 0 unless @songs && @songs[name]

        SONG_TICK * @weights[:sound_write] + song_notes(name) * @weights[:note_check]
      end

      # How many notes a song holds (its score is a list of [frame, frequency]
      # events). 0 for an unknown name.
      def song_notes(name)
        song = @songs && @songs[name]
        song ? song[:events].to_a.length : 0
      end

      def label_of(node)
        case node.kind
        when :fill_rect, :dma_fill_rect, :draw_rect_at then "#{node.kind} #{node[:w]}x#{node[:h]}"
        when :draw_text then "draw_text #{node[:text].inspect}"
        when :play_song then "play_song :#{node[:name]} (#{song_notes(node[:name])} notes)"
        when :beep then "beep #{node[:tone].inspect}"
        else node.kind.to_s
        end
      end
    end
  end
end

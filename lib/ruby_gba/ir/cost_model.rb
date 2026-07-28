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
    # Costs are in *scanlines* — the console draws the screen one scanline at a time,
    # so a scanline of drawing time is the natural unit, and the vertical blank (the
    # safe window to draw before the picture tears) is about 68 scanlines. So "this
    # frame costs 45 scanlines" means "it eats 45 of your ~68 safe scanlines." The
    # weights are measured on hardware (see the timing probe): reading VCOUNT right
    # after a known workload, so a glyph really is measured against a DMA fill. A game
    # dev can override any of them.
    #
    # Two things drive the cost. Drawing is dominated by DMA *operations*: a fill, a
    # blit, a save/restore is one DMA per row, and the per-row setup dwarfs the
    # per-pixel transfer — so a wide row and a narrow one cost about the same, and
    # cost scales with a rectangle's height (rows), not its area. And a pixel plotted
    # one at a time (a lone pixel, every font pixel) is far dearer than one moved by
    # DMA — so an opaque image streams cheaply while a transparent one, plotted pixel
    # by pixel, does not. Sound is priced in the same scanline unit.
    #
    # What the model gets exactly right is the *shape* of the work: a loop's body
    # counts once per iteration, a list-driven loop counts up to the list's capacity
    # (the worst it can reach), and a scene dispatch (case_var) costs its heaviest
    # branch, since only one branch runs per frame.
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

      # The characters a run-time digit field can show — one of these draws.
      DIGITS = ("0".."9").to_a.freeze

      # The per-frame drawing budget, in scanlines: the vertical blank — the safe
      # window to change the screen before the visible frame starts — is about 68 of
      # the console's 228 scanlines. Draw more than this in a single-buffered frame
      # and it tears.
      VBLANK_BUDGET = 68

      # The budget when the program double-buffers (draws to a hidden page shown all
      # at once): drawing isn't confined to the safe window, it can use the whole
      # frame (all 228 scanlines), and going over means a dropped frame (below
      # 60fps), never a tear.
      FRAME_BUDGET = 228

      # A ceiling on how much per-frame work a *single song* should cost on its own,
      # in scanlines. Playing a song re-checks every note against a frame counter on
      # every frame, so a long enough tune becomes real recurring work that has
      # nothing to do with drawing; past this the music guardrail flags it. (The
      # note-check cost itself is estimated, not measured — music timing is a
      # separate concern from the drawing the probe calibrated.)
      MUSIC_STEADY_BUDGET = 1.0

      # A sound op is a short burst of writes to the sound registers; these are the
      # write counts, priced in scanlines via the measured sound_write weight.
      # (Playing a song is priced separately — see #song_cost.)
      ENABLE_WRITES = 3  # power the sound hardware on
      BEEP_WRITES   = 2  # one channel-2 sound effect
      NOISE_WRITES  = 2  # one channel-4 percussion hit
      WAVE_WRITES   = 21 # a channel-3 tone: upload the wavetable to both banks + control
      STOP_WAVE_WRITES = 1 # silence the wave voice
      STOP_WRITES   = 4  # silence both music voices (channels 1 and 2)
      SONG_TICK     = 6 # per frame: advance the song's frame counter and wrap it at the end

      # Per-op costs in scanlines, measured on hardware by the timing probe (see the
      # class note). Override per-call: CostModel.new(glyph: 0.5).
      DEFAULT_WEIGHTS = {
        dma_setup:   0.102,   # the fixed per-row setup of a DMA transfer (a fill/blit/save row)
        dma_pixel:   0.00124, # one pixel filled or copied by DMA (the transfer, on top of setup)
        plot_pixel:  0.0267,  # one pixel written by hand — a lone pixel, a transparent blit, a font pixel
        sound_write: 0.0286,  # one write to a sound register (a beep, powering sound on)
        note_check:  0.003,   # per song note, the frame-counter check that runs every frame (estimated)
        # Logic / compute steps, in the same scanline unit (all estimated, not
        # measured — like note_check). A step is a plain data op (add, subtract,
        # compare, copy, move a value); it's the cheap baseline. Multiply is a few
        # cycles more. Divide is the outlier: this CPU has no divide instruction, so
        # a division traps into the BIOS Div routine — a bounded but real detour
        # (the trap in and out plus the division), on the order of tens of cycles,
        # roughly twenty steps' worth. That's exactly the hidden cost a per-frame
        # loop can bury. Keyed by op so the tiers stay tunable data, not code.
        op_step:     0.0022,  # add / sub / compare / copy / set — a single data-processing step
        op_mul:      0.0044,  # a multiply (multi-cycle)
        op_div:      0.0500,  # a divide — trap into the BIOS Div routine (SWI 0x06)
        # Tiled-mode per-frame upkeep. The display hardware composites the picture —
        # a background and its sprites — for free every scanline; what costs the CPU
        # is MOVING it each frame: rewriting each sprite's position and nudging the
        # scroll. Estimated, same scanline unit.
        obj_write:   0.086,   # rewrite one hardware sprite's position each frame (a few IO writes)
        scroll_write: 0.057,  # move a background: its two scroll-register writes
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

      # Fold runs of an identical repeated *block* of siblings into one group shown
      # once, with a "×N". Where #aggregate tames a run of the same single op (10
      # glyphs), this tames a repeated multi-op pattern — the wall of identical
      # "set, add, sub, negate, beep" groups an unrolled per-thing check (a brick
      # grid's collision) turns into. The group carries the whole run's rolled-up
      # cost; its children show the block once. Recurses into children first.
      def collapse_repeats(nodes)
        folded = nodes.map do |node|
          node[:children].to_a.empty? ? node : node.merge(children: collapse_repeats(node[:children]))
        end

        out = []
        i = 0
        while i < folded.length
          period, count = longest_repeat(folded, i)
          if count >= 2
            run = folded[i, period * count]
            out << { op: :group, label: "(repeated ×#{count})",
                     cost: run.sum { |node| node[:cost] }, count: count, children: folded[i, period] }
            i += period * count
          else
            out << folded[i]
            i += 1
          end
        end
        out
      end

      # Starting at +i+, the adjacent block-repeat that folds the most nodes: the
      # [period, count] maximizing period*count with at least two repeats (so the
      # smallest repeating unit wins a tie). [1, 1] means nothing repeats.
      def longest_repeat(nodes, i)
        best = [1, 1]
        ((nodes.length - i) / 2).downto(2) do |period|
          count = repeat_run(nodes, i, period)
          best = [period, count] if count >= 2 && (period * count) >= (best[0] * best[1])
        end
        best
      end

      # How many times the +period+-long block at +i+ repeats back to back.
      def repeat_run(nodes, i, period)
        first = nodes[i, period].map { |node| signature(node) }
        count = 1
        j = i + period
        while j + period <= nodes.length && nodes[j, period].map { |node| signature(node) } == first
          count += 1
          j += period
        end
        count
      end

      # A structural fingerprint: two nodes match when their op, label, size, and
      # children all match — so only truly identical blocks fold together.
      def signature(node)
        [node[:op], node[:label], node[:w], node[:h], node[:children].to_a.map { |child| signature(child) }]
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
        statements.sum { |node| steady(node) }
      end

      # Whether a program has a game loop (its cost recurs every frame) or is a
      # one-shot static draw.
      def looping?(program)
        program.children.any? { |node| node.kind == :loop }
      end

      # Whether the program opted into double buffering (a `buffered:` screen).
      # This decides which budget applies and how going over it reads: a torn
      # picture (single-buffer) versus a dropped frame (double-buffer).
      def buffered?(program)
        program.walk.any? { |node| node.kind == :screen && node[:buffered] }
      end

      # The per-frame draw budget that applies to this program: the whole frame
      # when it double-buffers, otherwise just the brief safe window.
      def budget_for(program)
        buffered?(program) ? FRAME_BUDGET : VBLANK_BUDGET
      end

      # The budget a single screen mode gets: the whole frame when buffered (it
      # draws to a hidden page shown all at once, so it can't tear), otherwise just
      # the brief safe window before the visible frame starts.
      def mode_budget(mode)
        mode == Modes::BUFFERED ? FRAME_BUDGET : VBLANK_BUDGET
      end

      # Whether the program mixes screen modes across its scenes (some direct,
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
        out.puts "draw-cost estimate (scanlines of the ~68-line vblank window, measured on hardware):"
        verdict_lines(program, out)
        glyph_footprint_lines(program, out)
      end

      # The drill-down: the verdict, then the (aggregated, depth-limited) cost tree,
      # then the hottest ops. +focus+ roots the tree at a named func; +max_depth+
      # bounds how deep it prints (deeper subtrees collapse to a rollup line).
      def render(program, out: $stdout, max_depth: 3, focus: nil, top: 5)
        tree = aggregate(analyze(program, focus: focus))
        out.puts "draw-cost estimate (scanlines of the ~68-line vblank window, measured on hardware):"
        if focus
          out.puts "  func :#{focus} ~ #{fmt(tree.sum { |node| node[:cost] })} scanlines"
        else
          verdict_lines(program, out)
        end
        render_tree(collapse_repeats(prune(tree, max_depth)), 1, out)
        hot = hot_ops(tree, top)
        out.puts "  hottest: " + hot.map { |h| "#{h[:op]}×#{h[:count]} ~#{fmt(h[:cost])}" }.join("  ") unless hot.empty?
        glyph_footprint_lines(program, out)
      end

      # One line per font whose text this program draws: how many of its glyphs are
      # actually reachable — the footprint a data-driven font would embed. Silent
      # when the program draws no text.
      def glyph_footprint_lines(program, out)
        IR::GlyphUsage.footprint(program).each do |f|
          out.puts "  text: font :#{f[:font]} draws #{f[:drawn]} of its #{f[:total]} glyphs"
        end
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
          glyphs: IR::GlyphUsage.footprint(program), # per-font reachable-glyph footprint
          tree: analyze(program),
        }
      end

      private

      # The selectivity-weighted cost of a subtree: how often the node's body
      # actually runs scales its cost, so what's left is the work that runs every
      # frame. A node that always runs weighs 1 (see #selectivity).
      def steady(node)
        selectivity(node) * raw_steady(node)
      end

      def raw_steady(node)
        case node.kind
        when :program, :loop, :else then node.children.sum { |child| steady(child) }
        # The condition is tested every frame, whichever way it goes — that's where a
        # collision test's comparison chain lives — so it's priced in full here; only
        # the branch bodies are scaled by how often they run.
        when :if then expr_cost(node[:cond]) + node.children.sum { |child| steady(child) } + (node[:else] ? steady(node[:else]) : 0)
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

      # How often an `if`'s body runs, read from its condition: a body behind a
      # `pressed` edge is a rare transition (never counts toward the steady load); a
      # `chance(p)` body holds p% of the time. A `held` or a plain comparison runs
      # every frame it's true, so it weighs 1 — as does any non-`if` node.
      def selectivity(node)
        return 1 unless node.kind == :if

        case node[:cond]&.kind
        when :pressed then 0
        when :chance then Rational(node[:cond][:percent], 100)
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
          out.puts "  boot draw ~ #{fmt(frame_cost(program))} scanlines   " \
                   "(no game loop — drawn once, then halts)   ok"
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
        out.puts "  steady per frame ~ #{fmt(steady)} of ~#{budget} scanlines (#{pct(steady, budget)})   " \
                 "#{over ? over_note : 'ok — fits the frame'}"
        if full > steady
          out.puts "  heaviest frame   ~ #{fmt(full)} scanlines   " \
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
          out.puts "  scene :#{s[:name]} (#{mode_label}) ~ #{fmt(s[:steady_cost])} of ~#{s[:budget]} scanlines " \
                   "(#{pct(s[:steady_cost], s[:budget])})   #{note}"
        end
      end

      def render_tree(nodes, depth, out)
        nodes.each do |node|
          tag = node[:collapsed] ? "  (+#{node[:collapsed]} ops collapsed)" : ""
          out.puts format("  %-52s ~%s", ("  " * depth) + node[:label] + tag, fmt(node[:cost]))
          render_tree(node[:children], depth + 1, out) unless node[:children].to_a.empty?
        end
      end

      # Format a scanline cost for a human: one decimal, "<0.1" for a tiny nonzero,
      # "0" for nothing. Keeps the drill-down readable when ops cost fractions.
      def fmt(cost)
        return "0" if cost.zero?
        return "<0.1" if cost.abs < 0.1

        format("%.1f", cost)
      end

      # A cost as a whole-percent share of a budget, e.g. "66%".
      def pct(cost, budget)
        "#{((cost.to_f / budget) * 100).round}%"
      end

      def leaf_count(node)
        node[:children].to_a.empty? ? 1 : node[:children].sum { |child| leaf_count(child) }
      end

      def all_leaves(nodes)
        nodes.flat_map { |node| node[:children].to_a.empty? ? [node] : all_leaves(node[:children]) }
      end

      # Catalogue the funcs (so a `call`/`case` can be costed), the list capacities
      # (so a repeat over a list can be bounded), the songs (so a `play_song` can be
      # costed by its note count), and the bitmaps (so a `blit` can be costed by its
      # image's size, which lives on the definition, not the blit op).
      def index(program)
        @funcs = {}
        @capacities = {}
        @songs = {}
        @bitmaps = {}
        @backing = {}
        program.walk do |node|
          @funcs[node[:name]] = node if node.kind == :func
          @capacities[node[:name]] = node[:capacity] if node.kind == :list_new
          @songs[node[:name]] = node if node.kind == :song
          # transparency ride-along: an opaque bitmap streams by DMA, a transparent
          # one is plotted pixel by pixel, and those cost very differently.
          @bitmaps[node[:name]] = [node[:width], node[:height], !node[:transparent].nil?] if node.kind == :bitmap
          @backing[node[:name]] = [node[:width], node[:height]] if node.kind == :backing_buffer
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
        case node.kind
        when :pixel then @weights[:plot_pixel]                     # one hand-plotted pixel
        when :fill_rect, :dma_fill_rect, :draw_rect_at then dma_rows_cost(node[:w], node[:h])
        when :clear_screen then dma_blob_cost(SCREEN_W * SCREEN_H) # the whole screen in one DMA
        when :draw_text then Fonts.get(node[:font]).text_pixels(node[:text]) * @weights[:plot_pixel]
        when :draw_digit then Fonts.get(node[:font]).max_glyph_pixels(DIGITS) * @weights[:plot_pixel]
        when :blit then blit_cost(node[:name])
        when :blit_pose then blit_cost(node[:poses].first)         # one pose draws; all are the same size
        when :save_region, :restore_region then region_cost(node[:buffer])
        # Tiled-mode per-frame upkeep: one position rewrite per presented sprite, and
        # the two scroll-register writes when a background moves.
        when :present_objects then node[:names].to_a.length * @weights[:obj_write]
        when :scroll_background then @weights[:scroll_write] + expr_cost(node[:x]) + expr_cost(node[:y])
        when :background then dma_blob(background_cells(node)) # one-time map stamp (boot, not per frame)
        when :play_song then song_cost(node[:name])
        when :beep then BEEP_WRITES * @weights[:sound_write]
        when :noise then NOISE_WRITES * @weights[:sound_write]
        when :wave then WAVE_WRITES * @weights[:sound_write]
        when :stop_wave then STOP_WAVE_WRITES * @weights[:sound_write]
        when :enable_sound then ENABLE_WRITES * @weights[:sound_write]
        when :stop_music then STOP_WRITES * @weights[:sound_write]
        # Logic / compute statements. Each is at least one step, plus the cost of the
        # expression it evaluates (so a divide buried in a value shows up). This is
        # what stops a compute loop — enemy AI, physics, a list walk — from reading
        # as free: run it N times and its per-op cost scales with N.
        when :set then @weights[:op_step] + expr_cost(node[:value])
        when :add, :sub then @weights[:op_step] + expr_cost(node[:operand])
        when :copy, :negate, :abs, :negate_abs then @weights[:op_step]
        when :clamp then 2 * @weights[:op_step] # a low compare and a high compare
        when :list_push then @weights[:op_step] + expr_cost(node[:value])
        when :list_set then @weights[:op_step] + expr_cost(node[:index]) + expr_cost(node[:value])
        when :list_drop then @weights[:op_step]
        else 0 # declarations, control markers, definitions: no per-frame work of their own
        end
      end

      # The cost of evaluating a value expression: every operator it's built from,
      # summed. A bare variable or literal is a load — effectively free — so the cost
      # is in the operators, and a divide weighs far more than an add (see the op_*
      # weights). This is why `(a * b) / c` in a per-frame loop isn't free, and why
      # the chain of comparisons behind a collision test (overlaps?) has a real cost.
      def expr_cost(value)
        return 0 unless value.is_a?(Node)

        case value.kind
        when :binop then op_weight(value[:op]) + expr_cost(value[:lhs]) + expr_cost(value[:rhs])
        when :neg then @weights[:op_step] + expr_cost(value[:operand])
        when :chance then @weights[:op_step] # a random draw and a compare
        else 0 # int / var_ref / held / pressed / read_scanline — a load, effectively free
        end
      end

      # An operator's weight: multiply and divide are their own (pricier) tiers;
      # everything else — add, subtract, the comparisons, the and/or that combine
      # conditions — is one plain step.
      def op_weight(op)
        case op
        when :* then @weights[:op_mul]
        when :/ then @weights[:op_div]
        else @weights[:op_step]
        end
      end

      # How many map cells a background stamps — the map is rows of tile cells, so
      # this is their total, the size of the one-time upload to tile memory.
      def background_cells(node)
        node[:map].to_a.sum { |row| row.respond_to?(:length) ? row.length : 1 }
      end

      # A rectangle filled/copied by DMA one row at a time (a fill, an opaque blit, a
      # save/restore): each row is a DMA, so the fixed per-row setup is paid h times,
      # and the pixels are transferred on top. This is why a tall rectangle costs more
      # than a wide one of the same area.
      def dma_rows_cost(w, h)
        h * @weights[:dma_setup] + w * h * @weights[:dma_pixel]
      end

      # A single DMA transfer of +pixels+ pixels in one shot (a whole-screen clear):
      # one setup, then the transfer. For a big blob the transfer dominates.
      def dma_blob_cost(pixels)
        @weights[:dma_setup] + pixels * @weights[:dma_pixel]
      end

      # The per-frame cost of playing +name+: its score is unrolled into one
      # frame-counter check per note, all re-run every frame, plus a small fixed
      # cost to advance and wrap the counter — so the recurring work grows with the
      # note count. An unknown name costs nothing (the backend reports it).
      def song_cost(name)
        return 0 unless @songs && @songs[name]

        SONG_TICK * @weights[:sound_write] + song_notes(name) * @weights[:note_check]
      end

      # How many notes a song holds — summed across its parts, since every part's
      # notes are re-checked each frame. 0 for an unknown name.
      def song_notes(name)
        song = @songs && @songs[name]
        return 0 unless song

        song[:voices].sum { |voice| voice[:events].to_a.length }
      end

      # A blit costs by how it's drawn: an opaque image streams by per-row DMA, but a
      # transparent one is plotted pixel by pixel (so its see-through pixels can be
      # skipped), which is far dearer. The size and transparency live on the bitmap
      # definition, catalogued in #index. An unknown image costs nothing.
      def blit_cost(name)
        w, h, transparent = @bitmaps && @bitmaps[name]
        return 0 unless w

        transparent ? w * h * @weights[:plot_pixel] : dma_rows_cost(w, h)
      end

      # Saving or restoring a patch copies its footprint by per-row DMA — the same
      # cost as an opaque blit of that size. The size lives on the backing_buffer
      # declaration, catalogued in #index. An unknown buffer costs nothing.
      def region_cost(name)
        w, h = @backing && @backing[name]
        w ? dma_rows_cost(w, h) : 0
      end

      def label_of(node)
        case node.kind
        when :fill_rect, :dma_fill_rect, :draw_rect_at then "#{node.kind} #{node[:w]}x#{node[:h]}"
        when :draw_text then "draw_text #{node[:text].inspect}"
        when :draw_digit then "draw_digit"
        when :blit then "blit :#{node[:name]}"
        when :blit_pose then "blit_pose (#{node[:poses].length} poses)"
        when :save_region then "save_region :#{node[:buffer]}"
        when :restore_region then "restore_region :#{node[:buffer]}"
        when :present_objects then "present_objects (#{node[:names].to_a.length} sprites)"
        when :scroll_background then "scroll_background :#{node[:name]}"
        when :background then "background :#{node[:name]}"
        when :play_song then "play_song :#{node[:name]} (#{song_notes(node[:name])} notes)"
        when :beep then "beep #{node[:tone].inspect}"
        else node.kind.to_s
        end
      end
    end
  end
end

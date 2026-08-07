# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # Turning the numbers into something a person reads — the text behind
      # `rom.explain`, and the same analysis as a Hash for tests and tools.
      #
      # The layout is deliberate. Anything the model could not price is announced FIRST,
      # loudly, so a silent zero can never pass for cheap. Then the costs, then the
      # verdict LAST, once the reader has seen where the time goes.
      #
      # Colour carries meaning and only one thing is allowed to be red: going over
      # budget. The drill-down tree uses a separate, cooler scale (#heat_for) that grades
      # a node by its share of the frame — a big slice is orange, meaning "your hottest
      # work", never "a problem". So a game that fits shows no alarm anywhere.
      module Report
        # The TREE heatmap, as a share of the frame's total drawn work — deliberately
        # never red. Red is reserved for the over-budget verdict, so a game that fits
        # shows no alarm anywhere in the drill-down; the tree only grades where the time
        # goes (a big slice is orange = "your hottest work", not "a problem to fix"). The
        # bands are shares of the frame total, so they don't depend on the hardware budget.
        HEAT_THRESHOLDS = { warm: 0.33, ok: 0.10 }.freeze

        # Print a short, human draw-cost estimate to +out+: the per-frame cost against
        # the frame budget for a game loop, or the one-time boot cost otherwise. (The
        # full drill-down tree comes later; this is the at-a-glance summary.)
        def report(program, out: $stdout, color: :auto, measured: nil)
          printer = Printer.for(out, color: color)
          tree = category_tree(program)
          frame_total = tree.sum { |node| node[:cost] }
          emit_unpriced_banner(printer, program)
          printer.puts header_line(measured)
          printer.puts "  per frame ~ #{fmt(frame_total)} scanlines" # the roll-up; the verdict/red is at the bottom
          tree.each { |cat| category_line(cat, printer, frame_total) } # section subtotals, no detail
          glyph_footprint_lines(program, printer)
          budget_summary_lines(program, printer, frame_total, measured: measured)
        end

        # The drill-down: the verdict, then the (aggregated, depth-limited) cost tree,
        # then the hottest ops. +focus+ roots the tree at a named func; +max_depth+
        # bounds how deep it prints (deeper subtrees collapse to a rollup line).
        def render(program, out: $stdout, max_depth: 3, focus: nil, top: 5, color: :auto, measured: nil)
          printer = Printer.for(out, color: color)
          tree = category_tree(program, focus: focus)
          frame_total = tree.sum { |node| node[:cost] } # the reference for a node's share-of-frame heat
          emit_unpriced_banner(printer, program) # loud, at the very top, before the estimate itself
          printer.puts header_line(measured)
          if focus
            printer.puts "  func :#{focus} ~ #{fmt(frame_total)} scanlines"
          else
            printer.puts "  per frame ~ #{fmt(frame_total)} scanlines" # the roll-up; the verdict/red is at the bottom
          end
          render_category_tree(tree, printer, frame_total, max_depth)
          render_hottest(tree, printer, top)
          glyph_footprint_lines(program, printer)
          budget_summary_lines(program, printer, frame_total, measured: measured) unless focus
        end

        # The report header. The cost TREE below is always the static estimate (the per-op
        # breakdown of where a frame's work goes — the emulator can't attribute per-op). The
        # VERDICT is measured on the emulator when a measurement is present, and an estimate
        # otherwise, so the header says which the reader is looking at.
        def header_line(measured)
          if measured
            "per-frame cost (breakdown is the static estimate; verdict measured on the emulator):"
          else
            "per-frame cost estimate (scanlines):"
          end
        end

        # One line per font whose text this program draws: how many of its glyphs are
        # actually reachable — the footprint a data-driven font would embed. Silent
        # when the program draws no text.
        def glyph_footprint_lines(program, printer)
          IR::GlyphUsage.footprint(program).each do |f|
            printer.puts "  text: font :#{f[:font]} draws #{f[:drawn]} of its #{f[:total]} glyphs"
          end
        end

        # The analysis as a plain Hash, ready to serialize (rom.explain format: :json).
        def as_json(program)
          {
            frame_cost: frame_cost(program) + mixer_cost(program), # everything on a frame, incl. the mixer
            steady_cost: steady_cost(program), # what recurs every frame from the op tree (the tear risk)
            frame_budget: FRAME_BUDGET,        # the whole-frame 60fps deadline
            budget: budget_for(program),       # the drawing/tear budget (vblank, or the whole frame when buffered)
            buffered: buffered?(program),      # double-buffered? (drawing can't tear, over frame = a dropped frame)
            looping: looping?(program),
            categories: category_tree(program).map { |c| { category: c[:category], cost: c[:cost] } }, # drawing/sound/logic subtotals
            scenes: scene_verdicts(program),   # per-scene cost vs each scene's own budget
            songs: song_verdicts(program),     # per-song music cost vs the music budget
            mixer: mixer_verdict(program),     # the software mixer's per-frame CPU (nil if no sampled sound)
            glyphs: IR::GlyphUsage.footprint(program), # per-font reachable-glyph footprint
            unestimated: unpriced_kinds(program).sort,  # op kinds the model can't price (counted as free)
            tree: category_tree(program),      # the frame's cost as drawing / sound / logic sections
          }
        end

        private

        # Render the categorized tree: each section (drawing / sound / logic) as a
        # subtotal header, then its detail nested under it. No verdicts here — just where
        # the frame's time goes; the pass/fail summary comes at the very bottom.
        def render_category_tree(categories, printer, frame_total, max_depth)
          categories.each do |cat|
            category_line(cat, printer, frame_total)
            detail = collapse_repeats(prune(aggregate(cat[:children]), max_depth))
            render_tree(detail, 3, printer, frame_total)
          end
        end

        # One section header: its name and rolled-up cost, tinted by its share of the
        # frame (like the rest of the tree). Shared by the full tree and the summary.
        def category_line(cat, printer, frame_total)
          printer.puts "    #{cat[:category].to_s.ljust(9)}~ #{fmt(cat[:cost])}", severity: heat_for(cat[:cost], frame_total)
        end

        # The costliest ops as a tight, aligned bullet list — "where the time really
        # goes" at a glance, rather than one dense run-on line.
        def render_hottest(tree, printer, top)
          hot = hot_ops(tree, top)
          return if hot.empty?

          printer.puts "  hottest:"
          # The count is how many times a FRAME runs it — 30 wall divides, not one in a
          # body that happens to loop — which is often the number that explains the cost.
          labels = hot.map { |h| h[:count] > 1 ? "#{h[:name]} ×#{h[:count]}" : h[:name].to_s }
          width = labels.map(&:length).max
          hot.zip(labels) { |h, label| printer.puts "    • #{label.ljust(width)}  ~#{fmt(h[:cost])}" }
        end

        # The drawing section's cost from the categorized tree (0 if it draws nothing) —
        # the figure the tear check judges against the vblank window.
        def drawing_total(tree)
          tree.find { |cat| cat[:category] == :drawing }&.dig(:cost) || 0
        end

        # The budget verdict, at the BOTTOM — the pass/fail summary once the costs are
        # laid out above. Two deadlines share the one frame: 60fps (the whole frame vs
        # ~228 scanlines) and, for a single-buffered game, tearing (drawing alone vs the
        # ~68-line vblank). A static program reports its one-time boot cost; a scene-
        # switching game reports each scene against its own mode's budget.
        def budget_summary_lines(program, printer, frame_total, measured: nil)
          unless looping?(program)
            printer.puts "  budget: boot cost #{fmt(frame_total)} scanlines, done once   ok", severity: :good
            return
          end

          printer.puts "  budget:"
          # Judge the RECURRING per-frame load — what every frame really pays. A one-off
          # spike (a transition repaint, an every() tick) is named separately below, not
          # judged as if it ran every frame: 60fps against the whole recurring load,
          # tearing against the recurring DRAWING alone (only drawing races the vblank).
          recurring = steady_cost(program) + mixer_cost(program)
          recurring_drawing = steady_drawing_cost(program)
          if measured
            # A measurement is the verdict: the real per-frame cost / frame rate, per scene
            # (or once for a single-loop game). The estimate's own within/over verdict is
            # suppressed — it's the one that can't see an unbounded loop or the DMA-stall.
            # Tearing stays an estimate: the emulator reads a settled framebuffer, so it
            # can't see a mid-frame tear.
            measured_verdict_lines(printer, measured)
            tear_budget_line(program, printer, recurring_drawing) unless mixed?(program)
          elsif mixed?(program)
            scene_verdict_lines(program, printer)
          else
            frame_budget_line(program, printer, recurring)
            tear_budget_line(program, printer, recurring_drawing)
          end

          if (mv = mixer_verdict(program))
            printer.puts "    (sound is the worst case — all #{mv[:voices]} mixer voices at once; a typical frame sounds fewer)"
          end

          if (cw = collision_worst_case(program)).positive?
            printer.puts "    (collision is the worst case — ~#{fmt(cw)} if every per-pixel test lands on one frame. " \
                         "Most frames the sprites miss and stop at the cheap box test.)"
          end

          if frame_total > recurring + 0.1
            printer.puts "    (a heavier frame reaches #{fmt(frame_total)} — the worst case for everything on it, " \
                         "not the every-frame cost)"
          end

          if measured
            blind_spot_note(program, printer)
          else
            estimate_only_hint(program, printer)
          end
        end

        # The measured verdict, one line per measured entry: a whole-frame reading for a
        # single-loop game (the nil key), or one per scene the profiler booted into. Each
        # result is plain data — { scanlines:, fps:, saturated: } — so this stays free of
        # the analyzer's own types.
        def measured_verdict_lines(printer, measured)
          width = measured.keys.map { |scene| (scene ? "scene :#{scene}" : "frame").length }.max
          measured.each do |scene, result|
            label = (scene ? "scene :#{scene}" : "frame").ljust(width)
            printer.puts "    #{label}  #{measured_verdict_text(result)}", severity: measured_severity(result)
          end
        end

        # No measurement ran (the emulator was not available), so the frame rate is an
        # estimate. If the estimate is also blind to part of the frame, say a real reading
        # is the only way to be sure. There is no flag to name — a build measures on its own
        # when it can.
        def estimate_only_hint(program, printer)
          blind = estimate_blind_spots(program)
          reason = blind.any? ? " — #{blind.join(' and ')} here can't be priced, so run it to be sure" : ""
          printer.puts "  estimate only — the emulator did not run, so the frame rate is not measured#{reason}"
        end

        # With a measurement in hand, note that the estimate's blind spots (an unbounded
        # loop, an unpriced op) ARE counted in the measured verdict — so the tree's zero for
        # them is not the whole story.
        def blind_spot_note(program, printer)
          blind = estimate_blind_spots(program)
          return if blind.empty?

          printer.puts "    (#{blind.join(' and ')} the tree can't price is included in the measured verdict above)"
        end

        # The per-frame budget check: the frame's estimated work against the ~228-scanline
        # frame. Over budget reads as over (blind spots only add cost, so that verdict is
        # safe). A frame that looks to fit but has a blind spot — an unbounded loop, an
        # unpriced op — can't be called "within budget": the estimate says it can't tell.
        def frame_budget_line(program, printer, frame_total)
          over = frame_total > FRAME_BUDGET
          blind = over ? [] : estimate_blind_spots(program)
          verdict =
            if over then "! estimate over budget"
            elsif blind.any? then "estimate can't tell — #{blind.join(' and ')} here isn't counted"
            else "estimate within budget"
            end
          printer.puts "    frame    ~#{fmt(frame_total)} of #{FRAME_BUDGET} scanlines (#{pct(frame_total, FRAME_BUDGET)})   #{verdict}",
                       severity: blind.any? ? :warm : severity_for(frame_total, FRAME_BUDGET)
        end

        # The tear check: drawing alone must land in the ~68-line vblank window, unless the
        # game double-buffers (draws to a hidden page shown at once, so it can't tear).
        def tear_budget_line(program, printer, drawing)
          if buffered?(program)
            printer.puts "    tearing  double-buffered — drawing can't tear   ok", severity: :good
            return
          end

          over = drawing > VBLANK_BUDGET
          printer.puts "    tearing  drawing #{fmt(drawing)} of #{VBLANK_BUDGET}-line vblank (#{pct(drawing, VBLANK_BUDGET)})   " \
                       "#{over ? '! over — the screen tears' : 'ok — no tearing'}",
                       severity: severity_for(drawing, VBLANK_BUDGET)
        end

        # One verdict line per scene, each against its own mode's budget — the report
        # for a game that runs some scenes direct-color and others tear-free.
        def scene_verdict_lines(program, printer)
          blind = estimate_blind_spots(program)
          scene_verdicts(program).each do |s|
            mode_label = s[:mode] == Modes::BUFFERED ? "tear-free" : "direct"
            note =
              if s[:over]
                s[:mode] == Modes::BUFFERED ? "! estimate over budget" : "! over budget — the screen tears"
              elsif blind.any?
                "estimate can't tell — #{blind.join(' and ')} here isn't counted"
              else
                s[:mode] == Modes::BUFFERED ? "estimate within budget" : "ok — fits the safe window"
              end
            hedged = !s[:over] && blind.any?
            printer.puts "  scene :#{s[:name]} (#{mode_label}) ~ #{fmt(s[:steady_cost])} of ~#{s[:budget]} scanlines " \
                         "(#{pct(s[:steady_cost], s[:budget])})   #{note}",
                         severity: hedged ? :warm : severity_for(s[:steady_cost], s[:budget])
          end
        end

        # Print the cost tree, tinting each line by its share of the frame's work (the
        # green→orange heatmap, never red) and marking a group heading — a per-file
        # subtotal — bold so the structure stands out from its leaves.
        def render_tree(nodes, depth, printer, frame_total)
          nodes.each do |node|
            tag = node[:collapsed] ? "  (+#{node[:collapsed]} ops collapsed)" : ""
            printer.cost_line(("  " * depth) + node[:label] + tag, fmt(node[:cost]),
                              severity: heat_for(node[:cost], frame_total), group: node[:op] == :group)
            render_tree(node[:children], depth + 1, printer, frame_total) unless node[:children].to_a.empty?
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

        def heat_for(cost, frame_total)
          return :good unless frame_total&.positive?

          share = cost.to_f / frame_total
          return :warm if share >= HEAT_THRESHOLDS[:warm]
          return :ok   if share >= HEAT_THRESHOLDS[:ok]

          :good
        end
      end
    end
  end
end

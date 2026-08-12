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
          frame_total = tree.sum(&:cost)
          emit_unpriced_banner(printer, program)
          emit_domain_banner(printer, program)
          emit_residual_banner(printer, program, measured)
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
          frame_total = tree.sum(&:cost) # the reference for a node's share-of-frame heat
          emit_unpriced_banner(printer, program)
          emit_domain_banner(printer, program) # loud, at the very top, before the estimate itself
          emit_residual_banner(printer, program, measured) unless focus # the tree below is one func, not the frame
          printer.puts header_line(measured)
          if focus
            printer.puts "  func :#{focus} ~ #{fmt(frame_total)} scanlines"
          else
            printer.puts "  per frame ~ #{fmt(frame_total)} scanlines" # the roll-up; the verdict/red is at the bottom
          end
          render_category_tree(tree, printer, frame_total, max_depth)
          render_hottest(tree, printer, top)
          glyph_footprint_lines(program, printer)
          stack_lines(program, printer) unless focus
          fast_memory_lines(program, printer) unless focus
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

        # What each declared layer turned out to hold, what it costs a frame, and how deep
        # the picture goes.
        #
        # A layer is a name an author writes; a LEVEL is what the console actually keeps,
        # and it has only four of them. Several layers landing on one level is the normal,
        # wanted answer rather than a compromise — so the report shows the levels, with
        # the layers that share each, and says how many are left. Same bargain as the
        # quick memory above: the framework picks, this says what it picked.
        #
        # ONE SECTION AND NOT TWO, deliberately. "What is at this depth" and "what does
        # this depth cost" are the same question asked twice, and a reader whose frame is
        # too full wants them on one line — the layer they would move something out of and
        # the reason to bother. Splitting them would mean reading the stack twice and
        # matching names by eye.
        def stack_lines(program, printer)
          picture = Stacking.picture(program)
          held_by = picture.stack.to_h { |layer| [layer, picture.in_layer(layer)] }
          return if held_by.each_value.all?(&:empty?)

          levels = Backends::GBA::MAX_LEVELS
          costs = layer_verdicts(program).to_h { |v| [v.name, v.cost] }
          printer.puts "  the stack, back to front (the console keeps #{levels} levels):"
          held_by.each do |layer, held|
            next if held.empty?

            printer.puts "    #{layer_level(picture, held).ljust(9)}:#{layer.to_s.ljust(12)}" \
                         "#{layer_cost_column(costs[layer])}#{layer_holds(picture, layer)}"
          end
          transparency_line(program, printer)
          used = picture.depths.count
          printer.puts "    #{used} of #{levels} levels used, #{levels - used} free"
          printer.puts "    #{layer_share_line(program, costs)}"
        end

        # What a layer costs every frame, or nothing at all when it costs nothing — and a
        # blank there is the thing worth seeing, because it is the whole bargain of the
        # tiled screen: a background is drawn by the display for free once it is up,
        # however big it is. Only what the framework has to write again each frame charges.
        def layer_cost_column(cost)
          (cost.nil? || cost.zero? ? "" : "~#{fmt(cost)}").ljust(8)
        end

        # THE HONEST LINE, and the section needs it more than it needs the numbers above.
        # Most of a frame sits at no depth — the game's own logic, its sound, drawing
        # written out by hand — so a column of small numbers with nothing to measure them
        # against reads as though the game costs what the stack costs.
        #
        # Measured against what a frame pays EVERY TIME, not against the worst-case total
        # the tree above shows. The costs in the column are per-frame upkeep, so they are
        # every-frame numbers, and dividing an every-frame number by a worst case would
        # make a stack that is most of the real load look like a twentieth of it. This is
        # the same figure the budget below judges, and it is read from the same place so
        # the two can never drift apart.
        def layer_share_line(program, costs)
          total = costs.values.sum
          return "these layers cost nothing a frame — the display draws what they hold" if total.zero?

          recurring = steady_cost(program) + standing_costs(program)
          "these layers cost ~#{fmt(total)} of the ~#{fmt(recurring)} scanlines a frame pays " \
            "every time; the rest of it sits at no depth"
        end

        # Which level a layer landed on. Nearly always one — a layer holding two
        # backgrounds is the exception, since scenery is the one thing that has to have a
        # level to itself.
        def layer_level(picture, held)
          at = held.map { |name| picture.depths[name] + 1 }.uniq.sort
          at.length == 1 ? "level #{at.first}" : "levels #{at.first}-#{at.last}"
        end

        # What a layer turned out to hold. Backgrounds are named, because an author named
        # them; sprites are counted, because their names are the framework's own.
        def layer_holds(picture, layer)
          scenery = picture.scenery.select { |node| node.layer == layer }.map { |node| "background :#{node.name}" }
          sprites = picture.objects.count { |node| node.layer == layer }
          scenery.push("#{sprites} sprite#{'s' if sprites > 1}") if sprites.positive?
          scenery.join(", ")
        end

        # A see-through layer is worth saying on its own line, and the cost column beside
        # it is the point: the display blends as it draws, so seeing through a layer is
        # free the way a fade is free. Without the line a reader has no way to tell a
        # stack that blends from one that does not.
        def transparency_line(program, printer)
          node = program.each.find { |n| n.kind == :layers && n.transparent }
          return unless node

          printer.puts "    :#{node.transparent} is #{node.transparency} see-through — " \
                       "the display blends it as it draws, for nothing"
          return unless program.each.any? { |n| n.kind == :fade }

          # The one thing a reader cannot see anywhere else. A fade uses the same blend
          # unit, so it takes that "for nothing" away for as long as it runs — and the two
          # verbs are usually written nowhere near each other.
          printer.puts "      ...except while a fade runs, which takes the same blend: " \
                       ":#{node.transparent} is solid until it lifts"
        end

        # What the build kept in the console's quick memory, and how much of it is left.
        #
        # This is the one decision the framework makes that changes how fast a game runs
        # without changing a line of it, so it does not get to be invisible. It names the
        # routines, says what they cost in memory, and says what a routine that did not
        # move would have needed — which is the number an author reaches for when they
        # want to make one fit.
        def fast_memory_lines(program, printer)
          return if @placement.nil? || @placement.funcs.empty?

          printer.puts "  kept in quick memory (code runs ~#{fmt(@weights[:fast_code_speedup])}x faster there):"
          @placement.funcs.each { |name| printer.puts "    #{quick_memory_label(name, program)}" }
          printer.puts format("    %s of 32K used, %s free",
                              kb(@placement.used_bytes), kb(@placement.free_bytes))
        end

        # What to call each thing that moved. Two of them are routines the machine sees but
        # the author never wrote, so they are named for what they do rather than by the
        # placeholder the build files them under.
        #
        # The interrupt routine also says its own figure, because it is the one thing here
        # that does NOT gain the factor on the line above: some of answering an interrupt is
        # the console's own doing and runs at the console's own speed wherever ours lives.
        def quick_memory_label(name, program)
          case name
          when :__frame then "the game loop"
          when :__interrupt
            "the routine that answers the display and the timers " \
              "(~#{fmt(interrupt_gain(program))}x here — part of an interrupt is the " \
              "console's own work, which does not move)"
          else "func :#{name}"
          end
        end

        # How much moving that routine is worth for THIS program, which depends on what
        # interrupts it: a bend does more of its own work per interrupt than a timer's tick,
        # so it gains more. Measured both ways (bend_line / tick_interrupt against their
        # _fast twins). A program that bends is judged on the bend, since that is what fires
        # 228 times a frame against a timer's handful.
        def interrupt_gain(program)
          if bend_verdict(program)
            @weights[:bend_line] / @weights[:bend_line_fast]
          else
            @weights[:tick_interrupt] / @weights[:tick_interrupt_fast]
          end
        end

        def kb(bytes) = format("%.1fK", bytes / 1024.0)

        # One line per font whose text this program draws: how many of its glyphs are
        # actually reachable — the footprint a data-driven font would embed. Silent
        # when the program draws no text.
        def glyph_footprint_lines(program, printer)
          IR::GlyphUsage.footprint(program).each do |f|
            printer.puts "  text: font :#{f.font} draws #{f.drawn} of its #{f.total} glyphs"
          end
        end

        # The analysis as a plain Hash, ready to serialize (rom.explain format: :json).
        def as_json(program)
          {
            # everything on a frame, including the standing costs the op tree can't show:
            # the sound mixer, a row-by-row bend's per-line interrupt, a timer's ticks, and
            # the sprites a placed fade has to hold itself off
            frame_cost: frame_cost(program) + standing_costs(program),
            steady_cost: steady_cost(program), # what recurs every frame from the op tree (the tear risk)
            frame_budget: FRAME_BUDGET,        # the whole-frame 60fps deadline
            budget: budget_for(program),       # the drawing/tear budget (vblank, or the whole frame when buffered)
            buffered: buffered?(program),      # double-buffered? (drawing can't tear, over frame = a dropped frame)
            looping: looping?(program),
            categories: category_tree(program).map { |c| { category: c.category, cost: c.cost } }, # drawing/sound/logic subtotals
            # The verdicts, flattened for the same reason the tree is (see #verdict_json).
            scenes: scene_verdicts(program).map { |v| verdict_json(v) }, # per-scene cost vs its own budget
            songs: song_verdicts(program).map { |v| verdict_json(v) },   # per-song music cost vs the music budget
            mixer: verdict_json(mixer_verdict(program)), # the mixer's per-frame CPU (nil if no sampled sound)
            bend: verdict_json(bend_verdict(program)),   # a bend's per-frame CPU (nil if nothing bends)
            ticks: verdict_json(tick_verdict(program)),  # each timer's handler (nil if no timer runs one)
            kept: verdict_json(kept_sprites_verdict(program)), # sprites held out of a fade (nil if none are)
            # what a frame spends at each declared depth — the other axis from the tree
            # below, and empty for a program that declares no layers
            layers: layer_verdicts(program).map { |v| verdict_json(v) },
            # per-font reachable-glyph footprint, flattened here because this hash is the
            # serialized output and a value object has no meaning once it is JSON
            glyphs: IR::GlyphUsage.footprint(program).map(&:to_h),
            unestimated: unpriced_kinds(program).sort,  # op kinds the model can't price (counted as free)
            # the frame's cost as drawing / sound / logic sections, flattened all the way down
            # because this hash is the serialized output (see #entry_json)
            tree: category_tree(program).map { |entry| entry_json(entry) },
          }
        end

        private

        # One verdict as plain data. Whether it is over its budget is worked out rather than
        # stored, so it is put back here — it is part of the answer a reader of the JSON
        # wants, and nothing on the other side of that boundary can work it out.
        def verdict_json(verdict)
          return nil unless verdict

          json = verdict.to_h
          json[:timers] = json[:timers].map { |timer| verdict_json(timer) } if json[:timers]
          verdict.respond_to?(:over?) ? json.merge(over: verdict.over?) : json
        end

        # One cost-tree entry as plain data, children and all. A field the entry has nothing
        # to say about is dropped rather than serialized as null, which keeps the JSON the
        # shape it has always been — an entry only carries the parts that apply to it.
        def entry_json(entry)
          entry.to_h.compact.merge(children: entry.children.map { |child| entry_json(child) })
        end

        # Render the categorized tree: each section (drawing / sound / logic) as a
        # subtotal header, then its detail nested under it. No verdicts here — just where
        # the frame's time goes; the pass/fail summary comes at the very bottom.
        def render_category_tree(categories, printer, frame_total, max_depth)
          categories.each do |cat|
            category_line(cat, printer, frame_total)
            detail = collapse_repeats(prune(aggregate(cat.children), max_depth))
            render_tree(detail, 3, printer, frame_total)
          end
        end

        # One section header: its name and rolled-up cost, tinted by its share of the
        # frame (like the rest of the tree). Shared by the full tree and the summary.
        def category_line(cat, printer, frame_total)
          printer.puts "    #{cat.category.to_s.ljust(9)}~ #{fmt(cat.cost)}", severity: heat_for(cat.cost, frame_total)
        end

        # The costliest ops as a tight, aligned bullet list — "where the time really
        # goes" at a glance, rather than one dense run-on line.
        def render_hottest(tree, printer, top)
          hot = hot_ops(tree, top)
          return if hot.empty?

          printer.puts "  hottest:"
          # The count is how many times a FRAME runs it — 30 wall divides, not one in a
          # body that happens to loop — which is often the number that explains the cost.
          labels = hot.map { |h| h.count > 1 ? "#{h.name} ×#{h.count}" : h.name.to_s }
          width = labels.map(&:length).max
          hot.zip(labels) { |h, label| printer.puts "    • #{label.ljust(width)}  ~#{fmt(h.cost)}" }
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
          # tearing against the work that runs before the frame's last write to the screen.
          recurring = steady_cost(program) + standing_costs(program)
          recurring_tear = steady_tear_cost(program)
          if measured
            # A measurement is the verdict: the real per-frame cost / frame rate, per scene
            # (or once for a single-loop game). The estimate's own within/over verdict is
            # suppressed — it's the one that can't see an unbounded loop or the DMA-stall.
            # Tearing stays an estimate: the emulator reads a settled framebuffer, so it
            # can't see a mid-frame tear.
            measured_verdict_lines(printer, measured)
            tear_budget_line(program, printer, recurring_tear) unless mixed?(program)
          elsif mixed?(program)
            scene_verdict_lines(program, printer)
          else
            frame_budget_line(program, printer, recurring)
            tear_budget_line(program, printer, recurring_tear)
          end

          if (mv = mixer_verdict(program))
            printer.puts "    (sound is the worst case — all #{mv.voices} mixer voices at once; a typical frame sounds fewer)"
          end

          bend_line(program, printer)
          tick_lines(program, printer)

          if (cw = collision_worst_case(program)).positive?
            printer.puts "    (collision is the worst case — ~#{fmt(cw)} if every per-pixel test lands on one frame. " \
                         "Most frames the sprites miss and stop at the cheap box test.)"
          end

          list_walk_line(program, printer)
          live_slot_line(program, printer)

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

        # HOW LONG THE LISTS WERE TAKEN TO BE, which the every-frame figure above turns on
        # and nothing in the program says. A walk is bounded by the capacity and by nothing
        # else, and a list sized so it can never overflow is nearly never full — so this is
        # the one assumption in the budget an author can correct, and it says how.
        def list_walk_line(program, printer)
          walks = list_walk_verdicts(program)
          return if walks.empty?

          at = walks.map { |walk| ":#{walk.name} #{walk.counted} of #{walk.capacity}" }.join(", ")
          if walks.all?(&:said)
            printer.puts "    (a list walk counts what the list usually holds — #{at}, the length you gave)"
          else
            printer.puts "    (a list walk counts what the list usually holds — #{at}, a guess. " \
                         "To give the real length, write estimate: { usually: N } on the list.)"
          end
        end

        # HOW MANY SLOTS WERE TAKEN TO BE IN USE. A pool's walk visits every slot it has and
        # that is counted in full — but the body behind the live test is not, and a pool is
        # sized for the worst moment of a game rather than a normal one. So this is the
        # second assumption in the budget an author can correct, and it says how.
        def live_slot_line(program, printer)
          guards = live_slot_verdicts(program)
          return if guards.empty?

          at = guards.map { |g| ":#{g.name} #{g.counted} of #{g.slots}" }.join(", ")
          if guards.all?(&:said)
            printer.puts "    (a pool walks every slot, and runs its body for the live ones — " \
                         "#{at}, the number you gave)"
          else
            printer.puts "    (a pool walks every slot, and runs its body for the live ones — #{at}, " \
                         "a guess. To give the real number, write estimate: { usually: N } on the pool.)"
          end
        end

        # The measured verdict, one line per measured entry: a whole-frame reading for a
        # single-loop game (the nil key), or one per scene the profiler booted into. Each
        # result is plain data — { scanlines:, fps:, saturated:, keys: } — so this stays
        # free of the analyzer's own types.
        def measured_verdict_lines(printer, measured)
          width = measured.keys.map { |scene| (scene ? "scene :#{scene}" : "frame").length }.max
          measured.each do |scene, result|
            label = (scene ? "scene :#{scene}" : "frame").ljust(width)
            printer.puts "    #{label}  #{measured_verdict_text(result)}", severity: measured_severity(result)
          end
          how_it_was_played_note(printer, measured)
        end

        # What the reading assumed the player was doing. A game costs what the player makes
        # it cost, so the number above means nothing without this: it is the worst frame
        # found while holding each button the game reads, in turn. When a held button is
        # what made a frame the worst one, the verdict line above already names it, and
        # this line explains where that came from.
        def how_it_was_played_note(printer, measured)
          return unless measured.values.any? { |result| result[:keys] }

          note = "    (the worst frame found. Each button this game reads was held in turn."
          note += " No button cost more than none held." unless measured.values.any? { |r| r[:keys].to_a.any? }
          printer.puts "#{note})"
        end

        # What a row-by-row bend costs the frame, and why. This is not in the tree above and
        # cannot be: the work is per LINE, not per statement, so a reader looking for where
        # the frame went would find nothing. It also says which part is the interrupt and
        # which part is the block, because the block is almost never the expensive half —
        # somebody hunting for the cost will otherwise rewrite the wrong thing.
        def bend_line(program, printer)
          verdict = bend_verdict(program) or return

          layers = verdict.layers.map { |name| ":#{name}" }.join(", ")
          printer.puts format("    bending %s costs ~%s a frame — the display is interrupted on all " \
                              "%d of its lines (~%s), and each row's own offset is worked out (~%s)",
                              layers, fmt(verdict.cost), verdict.lines,
                              fmt(verdict.interrupts), fmt(verdict.offsets))
        end

        # Below this a timer's per-frame cost prints as "<0.1" anyway, so there is nothing to
        # say about it.
        TICK_WORTH_SAYING = 0.1

        # What each timer's tick handler costs the frame, and why. Like a bend, the work is
        # not per statement — it is per tick, at a rate written somewhere else entirely (on
        # the `timer` that started it) — so a reader looking at the handler's body has no way
        # to see how often it runs. It also says which part is the interrupt, because for a
        # short body that is most of it and the body is the thing they would try to shorten.
        #
        # A timer slow enough to cost nothing measurable gets no line. Unlike a bend, which is
        # never cheap, most timers tick a handful of times a second, and a line reading "costs
        # ~<0.1" in the budget section only teaches a reader to skip the section. It is still
        # in the tree above, which is where everything is.
        def tick_lines(program, printer)
          verdict = tick_verdict(program) or return

          verdict.timers.each do |t|
            next if t.cost < TICK_WORTH_SAYING

            printer.puts format("    timer :%s costs ~%s a frame — it ticks %d times a second, so its body " \
                                "runs %s (interrupts ~%s, the body ~%s)",
                                t.name, fmt(t.cost), t.delivered, tick_rate_phrase(t),
                                fmt(t.interrupts), fmt(t.body))
            # Said here as well as in the guardrail, because this is the line where a reader
            # is working out where the frame went and the answer is "not where you asked".
            next if t.delivered >= t.hz

            printer.puts format("    (:%s was asked for %d a second. Its handler cannot finish " \
                                "between two ticks, so the console loses the rest.)",
                                t.name, t.hz)
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

        # The tear check: everything the frame does up to its last write to the screen must
        # land inside the ~68-line vblank window, unless the game double-buffers (it draws to
        # a hidden page shown all at once, so it cannot tear).
        #
        # It says "before the last draw" because that is not the same as "drawing", and the
        # difference is the whole reason an author reads this line: work that draws nothing
        # still pushes the last write later, and a frame that spends the window thinking
        # tears just as surely as one that spends it drawing.
        def tear_budget_line(program, printer, cost)
          if buffered?(program)
            printer.puts "    tearing  double-buffered — drawing can't tear   ok", severity: :good
            return
          end

          over = cost > VBLANK_BUDGET
          printer.puts "    tearing  #{fmt(cost)} of the #{VBLANK_BUDGET}-line vblank, everything " \
                       "up to the last draw (#{pct(cost, VBLANK_BUDGET)})   " \
                       "#{over ? '! over — the screen tears' : 'ok — no tearing'}",
                       severity: severity_for(cost, VBLANK_BUDGET)
        end

        # One verdict line per scene, each against its own mode's budget — the report
        # for a game that runs some scenes direct-color and others tear-free.
        def scene_verdict_lines(program, printer)
          blind = estimate_blind_spots(program)
          scene_verdicts(program).each do |s|
            mode_label = s.mode == Modes::BUFFERED ? "tear-free" : "direct"
            note =
              if s.over?
                s.mode == Modes::BUFFERED ? "! estimate over budget" : "! over budget — the screen tears"
              elsif blind.any?
                "estimate can't tell — #{blind.join(' and ')} here isn't counted"
              else
                s.mode == Modes::BUFFERED ? "estimate within budget" : "ok — fits the safe window"
              end
            hedged = !s.over? && blind.any?
            printer.puts "  scene :#{s.name} (#{mode_label}) ~ #{fmt(s.steady_cost)} of ~#{s.budget} scanlines " \
                         "(#{pct(s.steady_cost, s.budget)})   #{note}",
                         severity: hedged ? :warm : severity_for(s.steady_cost, s.budget)
          end
        end

        # Print the cost tree, tinting each line by its share of the frame's work (the
        # green→orange heatmap, never red) and marking a group heading — a per-file
        # subtotal — bold so the structure stands out from its leaves.
        def render_tree(nodes, depth, printer, frame_total)
          nodes.each do |node|
            tag = node.collapsed ? "  (+#{node.collapsed} ops collapsed)" : ""
            printer.cost_line(("  " * depth) + node.label + tag, fmt(node.cost),
                              severity: heat_for(node.cost, frame_total), group: node.op == :group)
            render_tree(node.children, depth + 1, printer, frame_total) unless node.children.empty?
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

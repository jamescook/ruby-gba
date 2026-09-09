# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # Turning the numbers into something a person reads — the text behind
      # `rom.explain`, and the same analysis as a Hash for tests and tools. Reopens
      # {CostModel} itself, the same way {Rollup}'s file does, rather than mixing in a
      # module: these methods read the collaborators #index already built (@tree,
      # @verdicts, @domains) off the one instance they're always called on.
      #
      # The layout is deliberate. Anything the model could not price is announced FIRST,
      # loudly, so a silent zero can never pass for cheap. Then the costs, then the
      # verdict LAST, once the reader has seen where the time goes.
      #
      # Colour carries meaning and only one thing is allowed to be red: going over
      # budget. The drill-down tree uses a separate, cooler scale (#heat_for) that grades
      # a node by its share of the frame — a big slice is orange, meaning "your hottest
      # work", never "a problem". So a game that fits shows no alarm anywhere.

      # The TREE heatmap, as a share of the frame's total drawn work — deliberately
      # never red. Red is reserved for the over-budget verdict, so a game that fits
      # shows no alarm anywhere in the drill-down; the tree only grades where the time
      # goes (a big slice is orange = "your hottest work", not "a problem to fix"). The
      # bands are shares of the frame total, so they don't depend on the hardware budget.
      HEAT_THRESHOLDS = { warm: 0.33, ok: 0.10 }.freeze

      # Print a short, human draw-cost estimate to +out+: the per-frame cost against
      # the frame budget for a game loop, or the one-time boot cost otherwise. (The
      # full drill-down tree comes later; this is the at-a-glance summary.)
      #
      # +measured+ is the emulator's reading of the frame, when one was taken — then it is
      # the verdict. +unmeasured+ says why there is none: :not_asked, or :no_emulator when
      # one was asked for and there was nothing to run it on. The two want different advice.
      def report(program, out: $stdout, color: :auto, measured: nil, unmeasured: :not_asked)
        index(program)
        printer = Printer.for(out, color: color)
        tree = @tree.category_tree(program)
        frame_total = tree.sum(&:cost)
        @verdicts.emit_nonsense_banner(printer, program)
        @verdicts.emit_unpriced_banner(printer, program)
        @domains.emit_domain_banner(printer, program)
        @verdicts.emit_residual_banner(printer, program, measured)
        printer.puts header_line(measured)
        frame_totals_lines(program, printer, frame_total)
        tree.each { |cat| category_line(cat, printer, frame_total) } # section subtotals, no detail
        glyph_footprint_lines(program, printer)
        budget_summary_lines(program, printer, frame_total, measured: measured, unmeasured: unmeasured)
      end

      # The drill-down: the verdict, then the (aggregated, depth-limited) cost tree,
      # then the hottest ops. +focus+ roots the tree at a named func; +max_depth+
      # bounds how deep it prints (deeper subtrees collapse to a rollup line).
      def render(program, out: $stdout, max_depth: 3, focus: nil, top: 5, color: :auto, measured: nil,
                 unmeasured: :not_asked)
        index(program)
        printer = Printer.for(out, color: color)
        tree = @tree.category_tree(program, focus: focus)
        frame_total = tree.sum(&:cost) # the reference for a node's share-of-frame heat
        @verdicts.emit_nonsense_banner(printer, program)
        @verdicts.emit_unpriced_banner(printer, program)
        @domains.emit_domain_banner(printer, program) # loud, at the very top, before the estimate itself
        @verdicts.emit_residual_banner(printer, program, measured) unless focus # the tree below is one func, not the frame
        printer.puts header_line(measured)
        if focus
          printer.puts "  func :#{focus} ~ #{CostModel.fmt(frame_total)} scanlines"
        else
          frame_totals_lines(program, printer, frame_total)
        end
        render_category_tree(tree, printer, frame_total, max_depth)
        render_hottest(tree, printer, top)
        glyph_footprint_lines(program, printer)
        stack_lines(program, printer) unless focus
        fast_memory_lines(program, printer) unless focus
        column_stretch_lines(printer) unless focus
        budget_summary_lines(program, printer, frame_total, measured: measured, unmeasured: unmeasured) unless focus
      end

      # THE TWO FRAMES, named, at the top. They can be a factor apart — a game whose work
      # sits behind `every 6` pays a sixth of it on a normal frame — and the report used to
      # lead with the worst one and judge the every-frame one at the bottom, so the headline
      # and the verdict were different frames with nothing saying so.
      #
      # The every-frame figure goes first because it is the one the budget judges and the
      # one a player feels. The worst frame stays, because the console has to survive it and
      # because it is what the tree below prices; naming it here is what stops the tree
      # reading as the cost of playing. Only one line when they are the same, which is most
      # games — a program with nothing timed or branched pays the same every frame.
      def frame_totals_lines(program, printer, frame_total)
        recurring = steady_cost(program) + @verdicts.standing_costs(program)
        unless @verdicts.looping?(program) && frame_total > recurring + 0.1
          printer.puts "  per frame ~ #{CostModel.fmt(frame_total)} scanlines"
          return
        end

        printer.puts "  every frame ~ #{CostModel.fmt(recurring)} scanlines   (what the budget below judges)"
        printer.puts "  worst frame ~ #{CostModel.fmt(frame_total)} scanlines   (the tree below prices this one)"
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
        costs = @verdicts.layer_verdicts(program).to_h { |v| [v.name, v.cost] }
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
        (cost.nil? || cost.zero? ? "" : "~#{CostModel.fmt(cost)}").ljust(8)
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

        recurring = steady_cost(program) + @verdicts.standing_costs(program)
        "these layers cost ~#{CostModel.fmt(total)} of the ~#{CostModel.fmt(recurring)} scanlines a frame pays " \
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

        fixed = Value.fixed_number(node.transparency)
        if fixed
          printer.puts "    :#{node.transparent} is #{fixed} see-through — " \
                       "the display blends it as it draws, for nothing"
        else
          # The one arrangement where it is not free — and only half of it: the blending
          # is still the display's, and it is the TELLING that costs.
          printer.puts "    :#{node.transparent} is as see-through as the game works out — " \
                       "the display blends it for nothing"
          printer.puts "      ...and the amount is written to it on every frame"
        end
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

        printer.puts "  kept in quick memory (code runs ~#{CostModel.fmt(@weights[:fast_code_speedup])}x faster there):"
        @placement.funcs.each do |name|
          printer.puts "    #{routine_size(name)}#{quick_memory_label(name, program)}"
        end
        printer.puts format("    %s of 32K used, %s free",
                            kb(@placement.used_bytes), kb(@placement.free_bytes))
        passed_over_lines(program, printer)
      end

      # How big each routine came to, in a column ahead of its name. Size is the whole of why
      # one routine is on this list and another is not, so it belongs beside them rather than
      # only in the total.
      def routine_size(name)
        bytes = @placement.sizes[name]
        bytes ? format("%8s  ", kb(bytes)) : " " * 10
      end

      # ...AND WHAT DID NOT FIT, which is the actionable half. A routine the frame spends real
      # time in and that just missed is exactly where a program lost the factor above, and
      # nothing else in a finished build can say so. The usual reason one is too big is that a
      # helper written once was called from several places and emitted at each of them, which
      # `func` is the answer to — so the line says that, because an author has no other way to
      # learn it.
      # WHY IT SAYS "WHEN ITS TURN CAME". The routines are offered the memory in order, dearest
      # first, so what one of them was offered is what was unspent AT THAT MOMENT — not what is
      # free at the end. The two are different numbers and both are true, which reads as a
      # contradiction to anyone who has not been told: a build can end with 8K free beside a
      # routine that was refused 12K, because the routine was asked first and the 8K went to
      # smaller ones after it. Without those four words an author reasonably concludes that
      # freeing memory will let the routine in, and it will not — nothing placed after it can
      # give it back its turn. Say when, and the next thought is the right one, which is to make
      # the routine smaller.
      def passed_over_lines(program, printer)
        return if @placement.passed_over.empty?

        @placement.passed_over.first(3).each do |over|
          printer.puts format("    (func :%s did not fit — it needs %s and %s was left when its " \
                              "turn came, so it runs from the cartridge.%s)",
                              over.name, kb(over.bytes), kb(over.room), repeated_note(program, over))
        end
      end

      # WHAT MAKES A ROUTINE TOO BIG, pointed at rather than guessed. Code is emitted where it
      # is written, so a routine grows for one of two reasons, and they are told apart by
      # HOW MANY LINES repeat rather than by how often one does.
      #
      # Several lines repeating the same number of times is a helper: a plain Ruby method
      # called from a build block runs at every call and records its ops there, so one written
      # once and called from eight places is emitted eight times. That one has a one-word fix,
      # and an author has no other way to learn it — so it is said.
      #
      # ONE line repeating is a single verb whose own expansion is large — a live number lays
      # out all ten shapes for every digit place — and telling that author to write a `func`
      # would be wrong. So the count is given and the advice is not.
      REPEATED_ENOUGH = 3

      def repeated_note(program, over)
        body = program.walk.find { |node| node.kind == :func && node.name == over.name }
        return "" unless body

        counts = body.walk.filter_map { |n| n.source&.to_s }.tally
        where, times = counts.max_by { |_, count| count } || []
        return "" if where.nil? || times < REPEATED_ENOUGH

        format(" Its most repeated line is %s, emitted %d times.%s",
               where.split("/").last, times, helper_advice(counts, times))
      end

      # Said only when the evidence is there: a run of DIFFERENT lines each emitted the same
      # number of times, which is what a helper looks like from here.
      def helper_advice(counts, times)
        return "" unless counts.count { |_, n| n == times } > 1

        " Several lines repeat together, which is a helper called from more than one place — " \
          "it is emitted at each of them, where a `func` is emitted once."
      end

      # WHICH SEE-THROUGH PICTURES SKIP THE ROWS THEY HAVE NOTHING IN, and which walk the lot.
      #
      # A picture drawn as a stretched column is normally shipped with a list, per column, of
      # where that column holds pixels — so a lamp in a square of ceiling costs its lit rows
      # and not its square. Two ceilings can stop that, and when one does the picture goes
      # back to walking every row of every column it draws. Nothing is WRONG with such a
      # picture, which is why this is not a guardrail: it is a speed the game did not get,
      # and until it was said here the only way to find out was to read the backend.
      #
      # SAID ONLY WHEN ONE MISSED, with the ones that fit listed beside it. A game whose
      # pictures all skip their empty rows has nothing to act on, and this report is long
      # enough already; a game with one that did not needs to see which is which.
      def column_stretch_lines(printer)
        decided = @column_stretches.to_h
        held_back = decided.reject { |_name, picture| picture.skips_empty_rows? }
        return if held_back.empty?

        printer.puts "  see-through pictures a stretched column draws:"
        decided.each do |name, picture|
          walks = picture.skips_empty_rows? ? "walks only the rows that hold pixels" : "walks every row"
          printer.puts format("    %9s  :%s — %s", "#{picture.height} rows", name, walks)
        end
        held_back.each { |name, picture| printer.puts "    (#{stretch_advice(name, picture)})" }
      end

      # ...and what to do about the one that missed. Each ceiling has its own answer, and the
      # answer is the point of the line — a picture can nearly always be made to fit.
      def stretch_advice(name, picture)
        missed = ":#{name} walks every row of every column it draws, and most of them draw nothing. "
        case picture.held_back_by
        when :too_tall
          "#{missed}A picture more than #{Backends::GBA::RUNS_MAX_ROWS} rows tall cannot ship " \
            "where its columns hold pixels. Make it #{Backends::GBA::RUNS_MAX_ROWS} rows or fewer."
        else
          "#{missed}Its columns hold pixels in too many separate places to ship. " \
            "Use fewer columns, or draw it from more than one picture."
        end
      end

      # What to call each thing that moved. Two of them are routines the machine sees but the
      # author never wrote, so they are named for what they do rather than by the placeholder
      # the build files them under — and named from {PlainWords}, which is where the progress
      # line that ran minutes earlier got the same two names.
      #
      # The interrupt routine also says its own figure, because it is the one thing here
      # that does NOT gain the factor on the line above: some of answering an interrupt is
      # the console's own doing and runs at the console's own speed wherever ours lives.
      def quick_memory_label(name, program)
        label = PlainWords.routine(name)
        return label unless name == Backends::GBA::Placement::IRQ_ROUTINE

        "#{label} (~#{CostModel.fmt(interrupt_gain(program))}x here — part of an interrupt " \
          "is the console's own work, which does not move)"
      end

      # How much moving that routine is worth for THIS program, which depends on what
      # interrupts it: a bend does more of its own work per interrupt than a timer's tick,
      # so it gains more. Measured both ways (bend_line / tick_interrupt against their
      # _fast twins). A program that bends is judged on the bend, since that is what fires
      # 228 times a frame against a timer's handful.
      def interrupt_gain(program)
        if @verdicts.bend_verdict(program)
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
          frame_cost: frame_cost(program) + @verdicts.standing_costs(program),
          steady_cost: steady_cost(program), # what recurs every frame from the op tree (the tear risk)
          frame_budget: FRAME_BUDGET,        # the whole-frame 60fps deadline
          budget: @verdicts.budget_for(program),       # the drawing/tear budget (vblank, or the whole frame when buffered)
          buffered: @verdicts.buffered?(program),      # double-buffered? (drawing can't tear, over frame = a dropped frame)
          looping: @verdicts.looping?(program),
          categories: @tree.category_tree(program).map { |c| { category: c.category, cost: c.cost } }, # drawing/sound/logic subtotals
          # The verdicts, flattened for the same reason the tree is (see #verdict_json).
          scenes: @verdicts.scene_verdicts(program).map { |v| verdict_json(v) }, # per-scene cost vs its own budget
          songs: @verdicts.song_verdicts(program).map { |v| verdict_json(v) },   # per-song music cost vs the music budget
          mixer: verdict_json(@verdicts.mixer_verdict(program)), # the mixer's per-frame CPU (nil if no sampled sound)
          bend: verdict_json(@verdicts.bend_verdict(program)),   # a bend's per-frame CPU (nil if nothing bends)
          ticks: verdict_json(@verdicts.tick_verdict(program)),  # each timer's handler (nil if no timer runs one)
          kept: verdict_json(@verdicts.kept_sprites_verdict(program)), # sprites held out of a fade (nil if none are)
          # what a frame spends at each declared depth — the other axis from the tree
          # below, and empty for a program that declares no layers
          layers: @verdicts.layer_verdicts(program).map { |v| verdict_json(v) },
          # per-font reachable-glyph footprint, flattened here because this hash is the
          # serialized output and a value object has no meaning once it is JSON
          glyphs: IR::GlyphUsage.footprint(program).map(&:to_h),
          unestimated: @verdicts.unpriced_kinds(program).sort,  # op kinds the model can't price (counted as free)
          # the frame's cost as drawing / sound / logic sections, flattened all the way down
          # because this hash is the serialized output (see #entry_json)
          tree: @tree.category_tree(program).map { |entry| entry_json(entry) },
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
          detail = Tree.collapse_repeats(Tree.prune(Tree.aggregate(cat.children), max_depth))
          render_tree(detail, 3, printer, frame_total)
        end
      end

      # One section header: its name and rolled-up cost, tinted by its share of the
      # frame (like the rest of the tree). Shared by the full tree and the summary.
      def category_line(cat, printer, frame_total)
        printer.puts "    #{cat.category.to_s.ljust(9)}~ #{CostModel.fmt(cat.cost)}", severity: heat_for(cat.cost, frame_total)
      end

      # The costliest ops as a tight, aligned bullet list — "where the time really
      # goes" at a glance, rather than one dense run-on line.
      def render_hottest(tree, printer, top)
        hot = Tree.hot_ops(tree, top)
        return if hot.empty?

        # ON AN AVERAGE FRAME, which is not the frame the tree above prices. The tree shows
        # what each thing costs on the frame it runs; this ranks what a frame really pays,
        # so a body that fires one frame in six is counted at a sixth. That is the list to
        # act on — the tree says where the work is, this says where the time goes — and the
        # two disagreeing is the point rather than a slip.
        printer.puts "  hottest, on an average frame:"
        # The count is how many times a FRAME runs it — 30 wall divides, not one in a
        # body that happens to loop — which is often the number that explains the cost.
        labels = hot.map { |h| h.count > 1 ? "#{h.name} ×#{h.count}" : h.name.to_s }
        width = labels.map(&:length).max
        hot.zip(labels) { |h, label| printer.puts "    • #{label.ljust(width)}  ~#{CostModel.fmt(h.cost)}" }
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
      def budget_summary_lines(program, printer, frame_total, measured: nil, unmeasured: :not_asked)
        # A verdict is a comparison, and every comparison against a NaN answers false — so a
        # frame that does not price to a number would print "within budget" and "no tearing"
        # with complete confidence. Refuse instead; the banner above names what produced it.
        #
        # THE NUMBERS BEING JUDGED, not the tree's total, and the difference is the whole
        # guard: a leaf is dropped from the tree unless its cost is positive, and a NaN is
        # not positive — so the tree quietly sums to something finite while the figure the
        # verdict actually reads is a NaN.
        unless judgeable?(program, frame_total)
          printer.puts "  budget: cannot be judged — the estimate is not a number (see above)",
                       severity: :hot
          return
        end

        unless @verdicts.looping?(program)
          printer.puts "  budget: boot cost #{CostModel.fmt(frame_total)} scanlines, done once   ok", severity: :good
          return
        end

        printer.puts "  budget:"
        # Judge the RECURRING per-frame load — what every frame really pays. A one-off
        # spike (a transition repaint, an every() tick) is named separately below, not
        # judged as if it ran every frame: 60fps against the whole recurring load,
        # tearing against the work that runs before the frame's last write to the screen.
        recurring = steady_cost(program) + @verdicts.standing_costs(program)
        recurring_tear = steady_tear_cost(program)
        if measured
          # A measurement is the verdict: the real per-frame cost / frame rate, per scene
          # (or once for a single-loop game). The estimate's own within/over verdict is
          # suppressed — it's the one that can't see an unbounded loop or the DMA-stall.
          # Tearing stays an estimate: the emulator reads a settled framebuffer, so it
          # can't see a mid-frame tear.
          measured_verdict_lines(printer, measured)
          tear_budget_line(program, printer, recurring_tear) unless @verdicts.mixed?(program)
        elsif @verdicts.mixed?(program)
          scene_verdict_lines(program, printer)
        else
          frame_budget_line(program, printer, recurring)
          tear_budget_line(program, printer, recurring_tear)
        end

        if (mv = @verdicts.mixer_verdict(program))
          printer.puts "    (sound is the worst case — all #{mv.voices} mixer voices at once; a typical frame sounds fewer)"
        end

        bend_line(program, printer)
        tick_lines(program, printer)

        if (cw = collision_worst_case(program)).positive?
          printer.puts "    (collision is the worst case — ~#{CostModel.fmt(cw)} if every per-pixel test lands on one frame. " \
                       "Most frames the sprites miss and stop at the cheap box test.)"
        end

        list_walk_line(program, printer)
        live_slot_line(program, printer)
        early_exit_line(program, printer)
        stretched_column_line(program, printer)

        if measured
          blind_spot_note(program, printer)
        else
          estimate_only_hint(program, printer, unmeasured)
        end
      end

      # HOW LONG THE LISTS WERE TAKEN TO BE, which the every-frame figure above turns on
      # and nothing in the program says. A walk is bounded by the capacity and by nothing
      # else, and a list sized so it can never overflow is nearly never full — so this is
      # the one assumption in the budget an author can correct, and it says how.
      def list_walk_line(program, printer)
        walks = @verdicts.list_walk_verdicts(program)
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
        guards = @verdicts.live_slot_verdicts(program)
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

      # HOW MANY PASSES A LOOP THAT STOPS EARLY WAS COUNTED AT. The third assumption in the
      # budget, and the one that can be furthest out — a ceiling is picked so it can never
      # be reached, and this kind of loop usually sits inside another, so the over-count
      # multiplies.
      def early_exit_line(program, printer)
        loops = @verdicts.early_exit_verdicts(program)
        return if loops.empty?

        at = loops.map { |l| "#{l.counted} of #{l.ceiling || '?'}" }.join(", ")
        if loops.all?(&:said)
          printer.puts "    (a loop that stops early counts the passes it usually makes — " \
                       "#{at}, the number you gave)"
        else
          printer.puts "    (a loop that stops early counts the passes it usually makes — #{at}, " \
                       "a guess. To give the real number, write estimate: { usually: N } on the repeat.)"
        end
      end

      # HOW TALL A STRETCHED COLUMN WAS COUNTED AT. The fourth assumption in the budget, and
      # for a first-person view it is by far the biggest: every height in one is worked out as
      # the game runs, because that is what perspective IS, so this decides what the whole
      # renderer costs.
      def stretched_column_line(program, printer)
        columns = @verdicts.stretched_column_verdicts(program)
        return if columns.empty?

        at = columns.map { |c| ":#{c.name} #{c.counted} of #{c.ceiling}" }.uniq.join(", ")
        if columns.all?(&:said)
          printer.puts "    (a stretched column counts the rows it usually draws — " \
                       "#{at}, the height you gave)"
        else
          printer.puts "    (a stretched column counts the rows it usually draws — #{at}, a " \
                       "guess. To give the real height, write estimate: { usually: N } on the column.)"
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
          printer.puts "    #{label}  #{@verdicts.measured_verdict_text(result)}", severity: @verdicts.measured_severity(result)
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
      # cannot be: the work is per ROW, not per statement, so a reader looking for where
      # the frame went would find nothing. It also splits the cost in two — what it takes
      # to hand the offsets to the display, and what it takes to work them out — because
      # which of those two is the expensive half depends on the lowering, and somebody
      # hunting for the cost will otherwise rewrite the wrong thing.
      #
      # WHICH LOWERING IT GOT IS SAID OUT LOUD, because the two prices are far enough
      # apart that a reader comparing two games, or the same game before and after an edit
      # to the block, would otherwise have no idea what changed (see BendForm).
      def bend_line(program, printer)
        verdict = @verdicts.bend_verdict(program) or return

        layers = verdict.layers.map { |name| ":#{name}" }.join(", ")
        printer.puts format("    bending %s costs ~%s a frame — %s, and each row's own offset is " \
                            "worked out (~%s)", layers, CostModel.fmt(verdict.cost), bend_feeding_phrase(verdict),
                            CostModel.fmt(verdict.offsets))
        kept_interrupt_note(program, printer) unless verdict.copied?
      end

      # How this bend's rows reach the display, in the words that name what it cost.
      def bend_feeding_phrase(verdict)
        if verdict.copied?
          format("the display's own copier hands each row its offset with no interruption at all, " \
                 "from a table this costs ~%s to fill", CostModel.fmt(verdict.filling))
        elsif verdict.filling.positive?
          format("the display is interrupted on all %d of its lines (~%s) to read each row out of a " \
                 "table that costs ~%s to fill",
                 verdict.lines, CostModel.fmt(verdict.interrupting), CostModel.fmt(verdict.filling))
        else
          format("the display is interrupted on all %d of its lines (~%s)",
                 verdict.lines, CostModel.fmt(verdict.interrupting))
        end
      end

      # ...and when it kept the interrupt, WHY — one line, because a reader who has seen
      # the copier priced in another game will ask, and because the answer is usually
      # something they can act on.
      def kept_interrupt_note(program, printer)
        reason = Backends::GBA::BendForm.kept_interrupt_reason(program) or return

        printer.puts "    (the copier could not feed this one: #{reason}.)"
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
        verdict = @verdicts.tick_verdict(program) or return

        verdict.timers.each do |t|
          next if t.cost < TICK_WORTH_SAYING

          printer.puts format("    timer :%s costs ~%s a frame — it ticks %d times a second, so its body " \
                              "runs %s (interrupts ~%s, the body ~%s)",
                              t.name, CostModel.fmt(t.cost), t.delivered, @tree.tick_rate_phrase(t),
                              CostModel.fmt(t.interrupts), CostModel.fmt(t.body))
          # Said here as well as in the guardrail, because this is the line where a reader
          # is working out where the frame went and the answer is "not where you asked".
          next if t.delivered >= t.hz

          printer.puts format("    (:%s was asked for %d a second. Its handler cannot finish " \
                              "between two ticks, so the console loses the rest.)",
                              t.name, t.hz)
        end
      end

      # No measurement ran, so the frame rate is an estimate — and WHY none ran, because the
      # two reasons want different next steps: not asked for, say how to ask; asked for with
      # no emulator to run it on, say what to build. If the estimate is also blind to part
      # of the frame, a real reading is the only way to be sure, whichever reason it was.
      def estimate_only_hint(program, printer, unmeasured)
        blind = @verdicts.estimate_blind_spots(program)
        sure = blind.any? ? " The estimate cannot price #{blind.join(' or ')} here, so run the game to be sure." : ""
        how =
          if unmeasured == :no_emulator
            "the measured answer needs the emulator, and it is not built. To build it, run `rake test:mgba`."
          else
            "the game did not run, so the frame rate is not measured. To measure it, call explain(measured: true)."
          end
        printer.puts "  estimate only — #{how}#{sure}"
      end

      # With a measurement in hand, note that the estimate's blind spots (an unbounded
      # loop, an unpriced op) ARE counted in the measured verdict — so the tree's zero for
      # them is not the whole story.
      def blind_spot_note(program, printer)
        blind = @verdicts.estimate_blind_spots(program)
        return if blind.empty?

        printer.puts "    (#{blind.join(' and ')} the tree can't price is included in the measured verdict above)"
      end

      # Can a verdict be given at all? Every figure a verdict reads has to be a real number,
      # including the ones the tree's own total does not contain.
      def judgeable?(program, frame_total)
        [frame_total, steady_cost(program), @verdicts.standing_costs(program),
         steady_tear_cost(program)].all? { |cost| cost.to_f.finite? }
      end

      # The per-frame budget check: the frame's estimated work against the ~228-scanline
      # frame. Over budget reads as over (blind spots only add cost, so that verdict is
      # safe). A frame that looks to fit but has a blind spot — an unbounded loop, an
      # unpriced op — can't be called "within budget": the estimate says it can't tell.
      def frame_budget_line(program, printer, frame_total)
        over = frame_total > FRAME_BUDGET
        blind = over ? [] : @verdicts.estimate_blind_spots(program)
        verdict =
          if over then "! estimate over budget"
          elsif blind.any? then "estimate can't tell — #{blind.join(' and ')} here isn't counted"
          else "estimate within budget"
          end
        printer.puts "    frame    ~#{CostModel.fmt(frame_total)} of #{FRAME_BUDGET} scanlines (#{CostModel.pct(frame_total, FRAME_BUDGET)})   #{verdict}",
                     severity: blind.any? ? :warm : @verdicts.severity_for(frame_total, FRAME_BUDGET)
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
        if @verdicts.buffered?(program)
          printer.puts "    tearing  double-buffered — drawing can't tear   ok", severity: :good
          return
        end

        over = cost > VBLANK_BUDGET
        printer.puts "    tearing  #{CostModel.fmt(cost)} of the #{VBLANK_BUDGET}-line vblank, everything " \
                     "up to the last draw (#{CostModel.pct(cost, VBLANK_BUDGET)})   " \
                     "#{over ? '! over — the screen tears' : 'ok — no tearing'}",
                     severity: @verdicts.severity_for(cost, VBLANK_BUDGET)
      end

      # One verdict line per scene, each against its own mode's budget — the report
      # for a game that runs some scenes direct-color and others tear-free.
      def scene_verdict_lines(program, printer)
        blind = @verdicts.estimate_blind_spots(program)
        @verdicts.scene_verdicts(program).each do |s|
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
          printer.puts "  scene :#{s.name} (#{mode_label}) ~ #{CostModel.fmt(s.steady_cost)} of ~#{s.budget} scanlines " \
                       "(#{CostModel.pct(s.steady_cost, s.budget)})   #{note}",
                       severity: hedged ? :warm : @verdicts.severity_for(s.steady_cost, s.budget)
        end
      end

      # Print the cost tree, tinting each line by its share of the frame's work (the
      # green→orange heatmap, never red) and marking a group heading — a per-file
      # subtotal — bold so the structure stands out from its leaves.
      def render_tree(nodes, depth, printer, frame_total)
        nodes.each do |node|
          tag = node.collapsed ? "  (+#{node.collapsed} ops collapsed)" : ""
          printer.cost_line(("  " * depth) + node.label + tag + how_often(node), CostModel.fmt(node.cost),
                            severity: heat_for(node.cost, frame_total), group: node.op == :group)
          render_tree(node.children, depth + 1, printer, frame_total) unless node.children.empty?
        end
      end

      # A body that does not run every frame says so on its own line, with what it really
      # costs an average one. This is the bridge between the two totals at the top: a tree
      # that adds up to the worst frame, with the lines that are not in a normal frame
      # marked, so a reader can see WHERE the difference went instead of being told twice
      # that there is one.
      # Timed triggers only. A scene branch also carries a factor — one scene runs a frame
      # and the estimate charges the dearest, so the others weigh nothing — but saying that
      # on the branch line needs more words than the label column has, and the case line
      # above it already shows the total matching the dearest arm. Left as it was.
      def how_often(node)
        return "" unless %i[every after].include?(node.op)
        return "  (once, not every frame)" if node.passes.zero?

        "  (~#{CostModel.fmt(node.cost * node.passes)} on an average frame)"
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

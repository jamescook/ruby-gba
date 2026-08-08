# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # Judgement: which budget a program is held to, whether it fits, and what the
      # estimate cannot vouch for. {Rollup} works out what a frame costs; this decides
      # what that number MEANS.
      #
      # There is more than one budget, because "over budget" means different things. A
      # single-buffered program has only the brief vblank window to draw in before the
      # picture tears; a double-buffered one draws to a hidden page and gets the whole
      # frame, where going over drops a frame instead. Music and the sampled-sound mixer
      # are judged apart from drawing, since they are CPU work that does not race the
      # vblank at all.
      #
      # The blind spots matter as much as the verdict. A loop whose trip count is only
      # known at run time counts as zero here, and an op nobody taught the model to price
      # counts as free — so both are reported rather than quietly folded into a pass.
      module Verdicts
        # The VERDICT scale, as fractions of the frame budget — the one place red comes
        # from. `:hot` is exactly `cost > budget`, the same test the over-budget verdict
        # uses, so a red verdict and the "over budget" wording can never disagree; the
        # cooler bands grade a frame that still fits.
        SEVERITY_THRESHOLDS = { hot: 1.0, warm: 0.66, ok: 0.33 }.freeze

        # The rate the screen refreshes at, and so the fastest a game loop can run: a loop
        # waits for the screen, so it runs 60, 30, 20... times a second and nothing in
        # between. A measured 60 means every pass met its frame.
        FULL_FRAME_RATE = 60

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

        # For a program already over budget at full capacity, the count at which each
        # growing loop tips the frame over. A loop whose trip count is a list's length
        # draws more as the list fills; this reports the break-even count and the
        # list's declared cap. Facts, not advice — only loops whose break-even is
        # actually reachable (below their cap, so capping lower would bring the frame
        # back under) are returned; a loop that fits even full is left out. The
        # guardrail turns these into a warning. Each entry:
        #   { list:, break_even:, cap:, budget:, steady: }
        def budget_thresholds(program)
          index(program)
          return [] unless looping?(program)

          budget = budget_for(program)
          # A list drawn item by item is a DRAWING cost, so measure it against the tear
          # risk (recurring drawing), not the whole per-frame load — the same reason the
          # draw-budget guardrail counts drawing alone.
          steady = steady_drawing_cost(program)
          return [] if steady <= budget # fits even at full capacity — nothing tips it over

          thresholds = capacity_bounded_loops(program).filter_map do |loop_node|
            name = loop_node[:count][:name]
            cap = @capacities[name]
            body = loop_node.children.sum { |child| steady(child, true) } # one iteration's drawing
            next unless body.positive?

            # cost(N) = (steady - cap*body) + N*body, so it crosses the budget at:
            break_even = (cap - ((steady - budget) / body)).floor
            next unless break_even.between?(0, cap - 1)

            { list: name, break_even: break_even, cap: cap, budget: budget, steady: steady,
              node: loop_node }
          end
          # One warning per list — a list drawn in several loops would otherwise repeat
          # the same advice; keep the tightest (lowest tip-over count).
          thresholds.group_by { |t| t[:list] }.map { |_name, ts| ts.min_by { |t| t[:break_even] } }
        end

        # The reachable repeat loops whose trip count is a list's length — so their
        # cost grows with a runtime count the list's capacity bounds.
        def capacity_bounded_loops(program)
          program.walk.select do |node|
            next false unless node.kind == :repeat

            count = node[:count]
            count.is_a?(Node) && count.kind == :list_len && @capacities[count[:name]]
          end
        end

        # Per-scene render verdicts, for a game that switches modes between scenes.
        # Each scene the loop dispatches to gets its own steady per-frame cost judged
        # against its own mode's budget — so a heavy direct-color scene is caught even
        # when another scene is buffered (which would otherwise widen the budget for
        # the whole program and hide it). Each entry:
        #   { name:, node:, mode:, steady_cost:, budget:, over: }
        def scene_verdicts(program)
          return [] unless looping?(program)

          # Asked for here rather than read off the index, so a program whose routines
          # can't be resolved to one screen each raises instead of being judged anyway.
          modes = Modes.resolve(program)
          index(program)
          modes.scene_funcs.map do |name|
            mode = modes.mode_of(name)
            cost = steady_func(name)
            budget = mode_budget(mode)
            { name: Modes.friendly_name(name), node: @funcs[name], mode: mode,
              steady_cost: cost, budget: budget, over: cost > budget }
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
              budget: MUSIC_STEADY_BUDGET, over: cost > MUSIC_STEADY_BUDGET,
              source: @songs[name].source }
          end
        end

        # The software mixer's per-frame cost, or nil when the program plays no sampled
        # sound. The mixer sums every sounding voice into the output buffer once a frame —
        # CPU work outside the drawing budget — so it's judged against the whole frame, not
        # the vblank window. Priced at the worst case (its full voice count) times the
        # buffer it fills each frame, plus the fixed per-frame overhead (clearing the
        # accumulator, copying the mixed buffer, the DMA/FIFO refill). Each entry:
        # { voices:, samples_per_frame:, rate:, cost:, budget:, over: }
        def mixer_verdict(program)
          return nil unless program.walk.any? { |node| node.kind == :play_sample }

          rate = mixer_rate(program)
          spf = [(rate + MIXER_FPS - 1) / MIXER_FPS, 1].max # samples the mixer fills each frame (ceil)
          mixing = MIXER_VOICES * spf * @weights[:mix_voice_sample]
          overhead = spf * @weights[:mix_overhead_sample]
          cost = mixing + overhead
          { voices: MIXER_VOICES, samples_per_frame: spf, rate: rate,
            cost: cost, budget: FRAME_BUDGET, over: cost > FRAME_BUDGET }
        end

        # What bending backgrounds row by row costs per frame, or nil when nothing bends.
        # One entry for the whole program, since every bend rides the same per-line
        # interrupt: the interrupt itself is paid once per line the display counts, and each
        # bend's own offset expression once per visible line.
        #
        # It is worth naming rather than folding into the tree because the shape surprises
        # people: most of the cost is not what you wrote in the block. Measured, the 228
        # interruptions come to about 20 scanlines and reading a sine table on every visible
        # row adds 4 — so the reader hunting for their frame would rewrite the sine lookup
        # and find four fifths of the cost still there. A block that is only a number costs
        # nothing measurable at all.
        # Each entry: { layers:, lines:, cost:, budget:, over: }
        def bend_verdict(program)
          bends = program.walk.select { |node| node.kind == :scroll_rows }
          return nil if bends.empty?

          interrupts = LINES_PER_FRAME * bend_line_weight
          offsets = in_fast_interrupts { bends.sum { |node| VISIBLE_LINES * bend_offset_cost(node) } }
          cost = interrupts + offsets
          { layers: bends.map { |node| node[:name] }.uniq, lines: LINES_PER_FRAME,
            interrupts: interrupts, offsets: offsets,
            cost: cost, budget: FRAME_BUDGET, over: cost > FRAME_BUDGET }
        end

        # What one line's interrupt costs. Keeping the routine it lands in in faster memory
        # buys back a good part of it, but NOT the measured factor the rest of the model
        # uses: a fair share of an interrupt is the console's own doing — stopping the game,
        # saving registers, handing control over and taking it back — and none of that runs
        # from our memory or gets any faster. So the two cases are two measured weights
        # rather than one weight and a discount.
        def bend_line_weight
          @fast_interrupts ? @weights[:bend_line_fast] : @weights[:bend_line]
        end

        # What working ONE row's offset out costs: the program's expression, plus anything
        # it put in the block before it. The register write and the row bookkeeping are
        # already in the per-line weight.
        def bend_offset_cost(node)
          expr_cost(node[:offset]) + node.children.sum { |child| op_cost(child) }
        end

        # The bend's per-frame cost as a plain number (0 when nothing bends), for adding to
        # a frame the way the mixer's is.
        def bend_cost(program)
          bend_verdict(program)&.fetch(:cost) || 0
        end

        # What a frame spends inside the routine the console jumps into when the display or
        # a timer announces something — the number that decides whether that routine is
        # worth keeping in faster memory (Backends::GBA::Placement#IRQ_ROUTINE).
        #
        # Today that is bending backgrounds row by row, all of which happens in there: the
        # per-line interrupt and the block that works each row's offset out. A timer's tick
        # body runs in there too and is not priced yet, so a program whose only interrupt is
        # a timer reads as spending nothing and its routine stays in the cartridge.
        def interrupt_frame_cost(program)
          bend_cost(program)
        end

        # The rate the mixer runs at — the one most of the program's samples were recorded
        # at (matching the backend), so the buffer size is right. Defaults when none say.
        def mixer_rate(program)
          rates = program.walk.select { |node| node.kind == :sample }.filter_map { |node| node[:rate] }
          return DEFAULT_MIXER_RATE if rates.empty?

          rates.group_by(&:itself).max_by { |_rate, list| list.size }.first
        end

        # The IR kinds this program uses that the model has no estimate for — neither
        # priced nor declared free (see FREE_STATEMENT_KINDS / FREE_VALUE_KINDS). They're
        # counted as zero, which would hide real work, so the estimate announces them.
        # Empty for a program the model fully understands.
        #
        # This walks the WHOLE program, not a frame of it. Asking a frame is what let
        # camera, fade and save_store sit unpriced: the kitchen-sink program that audits
        # the model holds every kind above its game loop, and a frame walk sees only the
        # loop's body — `wait_vblank, halt` in that program. So the one guard meant to
        # catch an op nobody priced was reading two free statements and finding nothing
        # to say.
        def unpriced_kinds(program)
          index(program) # resets the set, and catalogues what pricing an op needs
          program.walk { |node| audit_price(node) }
          @unpriced.dup
        end

        # Price one node for no reason but to find out whether the model knows how.
        # Control flow is skipped: it is costed by walking what it contains, never priced
        # on its own, so asking it would flag every `if` in the program.
        def audit_price(node)
          case Node::CATEGORY[node.kind]
          when :value then expr_cost(node)
          when :root, :control then nil
          else op_cost(node) # a statement — including a kind the table has never heard of
          end
        end

        # A loud line, above the estimate, naming any op the model couldn't account for —
        # so a newly-added op nobody taught it to price can't slip by as free. Silent for
        # a program the model fully understands.
        def emit_unpriced_banner(printer, program)
          kinds = unpriced_kinds(program)
          return if kinds.empty?

          printer.puts "!! cannot estimate: #{kinds.sort.join(', ')} — counted as FREE, so the real " \
                       "cost can be higher. Teach the cost model to price it.", emphasis: :banner
        end

        private

        # Which verdict band +cost+ falls in against +budget+ (see {Printer} for colours).
        # Red means "over the frame budget — it will tear or drop frames"; a missing or
        # zero budget can't be exceeded, so it reads as good/cheap.
        def severity_for(cost, budget)
          return :good unless budget&.positive?

          fraction = cost.to_f / budget
          return :hot  if fraction > SEVERITY_THRESHOLDS[:hot]
          return :warm if fraction >= SEVERITY_THRESHOLDS[:warm]
          return :ok   if fraction >= SEVERITY_THRESHOLDS[:ok]

          :good
        end

        # The software mixer's per-frame cost (0 when the program plays no samples) — it
        # runs every frame, so it's part of the recurring load, not the tree of ops.
        def mixer_cost(program)
          mixer_verdict(program)&.fetch(:cost) || 0
        end

        # A measured reading in words.
        #
        # TWO MEASUREMENTS, and which one to believe is the whole of this. The scanline
        # reading counts a frame's work, but it cannot count past a frame's worth — so as
        # it nears the ceiling it stops being an exact number, and "saturated" says so.
        # That is a fact about the MEASUREMENT, not about the program. When it is true, a
        # second run counts the game loop's passes directly, and THAT is the verdict: a
        # loop waits for the screen, so counting 60 a second means every pass met its
        # frame and the work fits, however close to the ceiling the first reading came.
        #
        # Reading saturation as "over budget" is what made a raycaster holding 60 report
        # over budget in red, in a sentence that argued with itself.
        def measured_verdict_text(result)
          held = held_suffix(result)
          measured = "measured ~#{fmt(result[:scanlines])} of #{FRAME_BUDGET} scanlines " \
                     "(#{pct(result[:scanlines], FRAME_BUDGET)})"
          return "#{measured}#{held}" unless result[:saturated]
          return "#{measured}#{held} — still #{FULL_FRAME_RATE} fps" if holds_full_rate?(result)
          return "measured over budget — running at ~#{result[:fps]} fps#{held}" if result[:fps]

          "measured over budget#{held} — the frame saturates (drops frames)"
        end

        # What the player was holding when this frame was measured. A game costs what the
        # player makes it cost, so a reading that only goes over budget while LEFT is down
        # has to say so — that is the difference between "your game is fine" and "your game
        # is fine until someone plays it". Empty when nothing held made the game dearer.
        def held_suffix(result)
          keys = result[:keys].to_a
          return "" if keys.empty?

          " while #{keys.map { |key| key.to_s.upcase }.join('+')} #{keys.length == 1 ? 'is' : 'are'} held"
        end

        # Whether the counted passes say the game met every frame. Nothing can run faster
        # than the screen, so this is the ceiling, not a target to beat.
        def holds_full_rate?(result)
          result[:fps] && result[:fps] >= FULL_FRAME_RATE
        end

        # Red is for a frame that really is over budget. A frame that nearly fills and
        # still holds the full rate is graded like any other that fits — warm, meaning
        # "your hottest work", not "a problem".
        def measured_severity(result)
          return :hot if result[:saturated] && !holds_full_rate?(result)

          severity_for(result[:scanlines], FRAME_BUDGET)
        end

        # The reasons the static estimate cannot vouch for the budget: a loop whose trip
        # count is only known at run time (its body counts as zero), or an op kind the model
        # can't price. Empty when the estimate accounts for the whole frame.
        def estimate_blind_spots(program)
          reasons = []
          reasons << "an unbounded loop" if unbounded_loop?(program)
          reasons << "a rectangle whose size the game works out" if runtime_sized_rect_anywhere?(program)
          reasons << "an unpriced op" unless unpriced_kinds(program).empty?
          reasons
        end

        # Whether the program has a repeat whose trip count has no provable bound — not a
        # literal, not a capacity-bounded list — so the estimate counts its body as zero.
        def unbounded_loop?(program)
          index(program)
          program.walk.any? { |node| node.kind == :repeat && repeat_factor(node).last.include?("unbounded") }
        end

        # Whether the program fills a rectangle whose width or height it works out as it
        # runs. The estimate counts that fill as zero for the same reason it counts an
        # unbounded loop as zero — there is no provable size to charge for.
        def runtime_sized_rect_anywhere?(program)
          program.walk.any? { |node| runtime_sized_rect?(node) }
        end
      end
    end
  end
end

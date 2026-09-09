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
      #
      # +tree+ is wired in AFTER construction (see #tree=), not taken as a constructor
      # argument: #residual_note asks {Tree}#category_tree for the estimate it checks
      # against a measurement, and Tree asks back for the standing costs here (a bend, a
      # timer's ticks, the mixer) — the same two-phase dance {Walker} and {Pricing} do,
      # for the same reason.
      class Verdicts
        attr_writer :tree

        def initialize(weights:, catalogue:, walker:, pricing:, fast_frame:, fast_interrupts:)
          @weights = weights
          @catalogue = catalogue
          @walker = walker
          @pricing = pricing
          @fast_frame = fast_frame
          @fast_interrupts = fast_interrupts
        end
        # The VERDICT scale, as fractions of the frame budget — the one place red comes
        # from. `:hot` is exactly `cost > budget`, the same test the over-budget verdict
        # uses, so a red verdict and the "over budget" wording can never disagree; the
        # cooler bands grade a frame that still fits. A HEDGED verdict — a blind spot the
        # estimate cannot count, or a cost within the estimate's own margin of the line —
        # is warm on either side of it, because what the report is saying there is that it
        # does not know.
        SEVERITY_THRESHOLDS = { hot: 1.0, warm: 0.66, ok: 0.33 }.freeze

        # HOW FAR THE ESTIMATE CAN BE OUT, as a fraction of the budget a verdict is judged
        # against. A tenth, because a tenth is the band the corpus is scored by: `rake
        # cost:check` counts an example as close when the estimate is within a tenth of the
        # console, and most of the corpus sits inside it. So a verdict within a tenth of its
        # limit is not a verdict — the real frame can be on either side of the line — and the
        # report says "close" there rather than "fits" or "over".
        MARGIN = 0.1

        def close_to_limit?(cost, budget)
          (cost - budget).abs <= budget * MARGIN
        end

        # The rate the screen refreshes at, and so the fastest a game loop can run: a loop
        # waits for the screen, so it runs 60, 30, 20... times a second and nothing in
        # between. A measured 60 means every pass met its frame.
        FULL_FRAME_RATE = 60

        # WHEN THE BREAKDOWN IS TOO SMALL TO BE THE WHOLE FRAME (see #residual_note). Two
        # tests, and it takes both, because either one alone is noise.
        #
        # The SHARE has to clear the model's own honest error. The keep-honest tests hold
        # each standing cost to a quarter (test/test_cost_calibration.rb), and the estimate
        # answers a deliberately different question from the reading on top of that — it
        # counts a list-driven loop at capacity where a real frame draws what the list
        # holds. Half leaves that whole band alone and still catches a factor: the four
        # examples that fire today read 0.40 to 0.44, and the nearest one that does not is
        # 0.57.
        #
        # The GAP is what stops the share from firing on nothing. A game loop that does
        # NOTHING AT ALL measures 0.20 scanlines — the wake from the vblank, the branch —
        # and the estimate says 0.00, so a tiny program is 0% accounted for and always will
        # be. Three tiled examples sit there. Five scanlines is far above that floor and is
        # about 2% of a frame, which is the least worth interrupting somebody for.
        RESIDUAL_SHARE = 0.5
        RESIDUAL_GAP = 5.0

        # Whether a program has a game loop (its cost recurs every frame) or is a
        # one-shot static draw.
        def looping?(program)
          program.children.any? { |node| node.kind == :loop }
        end

        # Whether the program opted into double buffering (a `buffered:` screen).
        # This decides which budget applies and how going over it reads: a torn
        # picture (single-buffer) versus a dropped frame (double-buffer).
        def buffered?(program)
          program.walk.any? { |node| node.kind == :screen && node.buffered }
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
        #
        # AT CAPACITY THROUGHOUT, which is the one place in the model that asks for that.
        # Everywhere else a walk over a list, and a pool's body, are counted at what those
        # usually hold, because that is what a frame really pays. This question is the other
        # one — how long can the list get before a frame stops fitting — and its answer is
        # only interesting for a game that fits today. Asked of the typical figures, it would
        # go quiet for exactly the games it is for. A pool alongside is held full for the same
        # reason: the list's break-even has to be solved against the rest of a full frame.
        def budget_thresholds(program)
          return [] unless looping?(program)

          budget = budget_for(program)
          # WHICH COST RACES WHICH DEADLINE, the same split the draw-budget guardrail makes.
          # On a single screen the risk is tearing, and what races the brief safe window is
          # everything the frame does up to its last write to the screen. A double-buffered
          # game cannot tear at all, so its risk is the whole frame's work against 60fps.
          steady = @walker.at_full_capacity { frame_load(program) }
          return [] if steady <= budget # fits even at full capacity — nothing tips it over

          # ONE ANSWER PER LIST, not per loop, and the walks over a list are summed to get
          # it. They all grow together — a body walked in three loops costs three walks per
          # item — so what capping the list saves is the sum of them. Solved one loop at a
          # time, no single walk over a list a game walks repeatedly is big enough on its own
          # to be worth capping, and the list goes unwarned.
          capacity_bounded_loops(program).group_by { |node| node.count.name }.filter_map do |name, loops|
            # THE LENGTH THE AUTHOR ASKED FOR, not the power of two the ring rounded it up
            # to. Whether this warning is worth making turns on whether the list can really
            # get that long, and the rounding is headroom for the mask rather than for the
            # game: a snake whose board holds 340 cells was told its frame gives out at 459.
            cap = @catalogue.declared[name]
            body = @walker.at_full_capacity do
              loops.sum { |node| node.children.sum { |child| @walker.steady(child) } }
            end
            next unless body.positive? # what one item of the list costs the frame

            # cost(N) = (slots - N)*body less than the whole, so it crosses the budget at:
            break_even = (@catalogue.capacities[name] - ((steady - budget) / body)).floor
            next unless break_even.between?(0, cap - 1)

            Verdict::ListWalk.new(list: name, break_even: break_even, cap: cap, budget: budget,
                                  steady: steady, node: loops.first)
          end
        end

        # The recurring per-frame load the deadline is judged against: the work that races
        # the safe window when what is at risk is a tear, the whole frame (the mixer
        # included) when it is the frame rate.
        def frame_load(program)
          return @walker.steady_tear_cost(program) unless buffered?(program)

          @walker.steady_cost(program) + mixer_cost(program)
        end

        # The reachable repeat loops whose trip count is a list's length — so their
        # cost grows with a runtime count the list's capacity bounds.
        def capacity_bounded_loops(program)
          program.walk.select do |node|
            next false unless node.kind == :repeat

            count = node.count
            count.is_a?(Node) && count.kind == :list_len && @catalogue.capacities[count.name]
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

          # Asked for here rather than read off the catalogue, so a program whose routines
          # can't be resolved to one screen each raises instead of being judged anyway.
          modes = Modes.resolve(program)
          modes.scene_funcs.map do |name|
            mode = modes.mode_of(name)
            cost = @walker.steady_func(name)
            budget = mode_budget(mode)
            Verdict::Scene.new(name: Modes.friendly_name(name), node: @catalogue.funcs[name], mode: mode,
                               steady_cost: cost, budget: budget)
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
          names = program.walk.select { |node| node.kind == :play_song }.map { |node| node.name }.uniq
          names.filter_map do |name|
            next unless @catalogue.songs[name]

            cost = @pricing.song_cost(name)
            Verdict::Song.new(name: name, notes: @pricing.song_notes(name), steady_cost: cost,
                              budget: MUSIC_STEADY_BUDGET, source: @catalogue.songs[name].source)
          end
        end

        # The software mixer's per-frame cost, or nil when the program plays no sampled
        # sound. The mixer sums every sounding voice into the output buffer once a frame —
        # CPU work outside the drawing budget — so it's judged against the whole frame, not
        # the vblank window. Priced at the voices that can SOUND (see #sounding_voices) times
        # the buffer it fills each frame, plus the fixed per-frame overhead (clearing the
        # accumulator, copying the mixed buffer, the DMA/FIFO refill). Each entry:
        # { voices:, capacity:, samples_per_frame:, rate:, cost:, budget:, over: }
        def mixer_verdict(program)
          plays = program.walk.select { |node| node.kind == :play_sample }
          return nil if plays.empty?

          rate = mixer_rate(program)
          spf = [(rate + MIXER_FPS - 1) / MIXER_FPS, 1].max # samples the mixer fills each frame (ceil)
          voices = sounding_voices(plays)
          mixing = voices * spf * @weights[:mix_voice_sample]
          overhead = spf * @weights[:mix_overhead_sample]
          cost = mixing + overhead
          Verdict::Mixer.new(voices: voices, capacity: MIXER_VOICES, samples_per_frame: spf,
                             rate: rate, cost: cost, budget: FRAME_BUDGET)
        end

        # HOW MANY VOICES CAN BE SOUNDING AT ONCE, which is what the mixer costs — not how
        # many it could hold.
        #
        # The mix routine walks its slots once per output sample per SOUNDING voice, and an
        # idle slot is skipped after a load, a compare and a branch. So its cost is a straight
        # line in the number really sounding, and charging the full capacity of eight to a
        # program that plays three is charging nearly three times what it spends.
        #
        # A LOOPING VOICE IS EXACT: it never stops, so every one of them sounds on every
        # frame, and there is nothing to work out.
        #
        # A ONE-SHOT IS BOUNDED BY WHAT CAN HAPPEN ON ONE FRAME, and that the program does
        # say, in the one shape that triggers sound: a counter stepped each frame and tested
        # against a number. Two plays under `beat == 0` and `beat == 24` can never happen
        # together, because a variable holds one value — which is a different thing from two
        # buttons that merely happen never to be pressed together, and is why this can be read
        # off the program where that cannot (see the cost model header on what is never
        # estimated).
        #
        # WHAT IT CANNOT SEE is a clip still sounding when the next one starts, which adds a
        # voice the triggers alone do not show. Measured against the reference interpreter,
        # which models a voice's whole life, this lands between a typical frame and the worst
        # one on every shape tried — and the report says what it counted so a reader can tell.
        def sounding_voices(plays)
          looping, one_shot = plays.partition(&:loop)
          [looping.length + most_playing_together(one_shot), MIXER_VOICES].min
        end

        # The most one-shot plays that can happen on the same frame. Two of them cannot, when
        # they sit under tests wanting one variable to hold two different values.
        #
        # Asked by trying each set of values the tests mention and counting the plays it lets
        # through — a play is let through when every test above it is satisfied, and a play
        # under no test at all is let through by all of them. The values worth trying are the
        # ones the program writes: settling a variable on some OTHER value only turns plays
        # off, so it can never be the busiest frame.
        #
        # Trying every combination of them is a product, and a program testing several
        # variables against many values could make it a large one. Past a ceiling this gives
        # up and says every play, which is what the whole thing said before it counted at all.
        COMBINATIONS_WORTH_TRYING = 4096

        def most_playing_together(plays)
          return 0 if plays.empty?

          # Keyed by IDENTITY: two plays of the same sample under different tests are equal as
          # trees, and a hash comparing them by value would keep one entry for both.
          tests = {}.compare_by_identity
          plays.each { |play| tests[play] = equality_tests_above(play) }

          values = Hash.new { |h, k| h[k] = [] }
          tests.each_value { |above| above.each { |var, val| values[var] |= [val] } }
          return plays.length if values.empty?

          combinations = values.values.reduce(1) { |n, vals| n * vals.length }
          return plays.length if combinations > COMBINATIONS_WORTH_TRYING

          vars = values.keys
          values.values.first.product(*values.values.drop(1)).map do |picked|
            frame = vars.zip(Array(picked)).to_h
            plays.count { |play| tests[play].all? { |var, val| frame[var] == val } }
          end.max
        end

        # The equality tests a statement sits under, as { variable => value }, read from every
        # `if` above it that compares a variable with a number. A statement in an ELSE branch
        # is under the NEGATION of its test, which says nothing about what else can happen, so
        # it collects nothing from that one.
        def equality_tests_above(node)
          tests = {}
          child = node
          while (parent = child.parent)
            cond = parent.kind == :if && parent.children.include?(child) ? parent.cond : nil
            if cond&.kind == :binop && cond.op == :== &&
               cond.lhs&.kind == :var_ref && cond.rhs&.kind == :int
              tests[cond.lhs.name] = cond.rhs.value
            end
            child = parent
          end
          tests
        end

        # What bending backgrounds row by row costs per frame, or nil when nothing bends.
        # One entry for the whole program, since every bend is fed the same way.
        #
        # It is worth naming rather than folding into the tree because the shape surprises
        # people, and it surprises them differently on the two lowerings. WHERE AN ENGINE
        # FEEDS THE DISPLAY the cost IS the block, run 160 times at the frame boundary, and
        # a reader hunting for their frame is looking at the right thing. WHERE THE
        # INTERRUPT DOES, the 228 interruptions come to about 20 scanlines on their own, so
        # the same reader would rewrite the block and find most of the cost still there.
        # Each entry: { layers:, lowering:, lines:, cost:, budget:, over: }
        def bend_verdict(program)
          bends = program.walk.select { |node| node.kind == :scroll_rows }
          return nil if bends.empty?

          form = Backends::GBA::BendForm
          copied = form.copier?(program)
          latched = form.latched?(program)
          # The block runs at the frame boundary, into a table — except in a program with no
          # frame, where it runs inside the routine the display interrupts into. Those two
          # places may have been kept in the quick memory independently of each other.
          offsets = bend_offsets_cost(bends, latched)
          # Each bending layer has a table of its own to fill, so two layers is twice that
          # work. The interrupt on top is ONE announcement however many layers read from it.
          filling = latched ? bends.length * VISIBLE_LINES * bend_row_copied_weight : 0
          interrupting = copied ? 0 : LINES_PER_FRAME * bend_line_weight
          Verdict::Bend.new(layers: bends.map { |node| node.name }.uniq,
                            lowering: copied ? :copier : :interrupt, lines: LINES_PER_FRAME,
                            filling: filling, interrupting: interrupting, offsets: offsets,
                            cost: filling + interrupting + offsets, budget: FRAME_BUDGET)
        end

        def bend_offsets_cost(bends, latched)
          each = -> { bends.sum { |node| VISIBLE_LINES * bend_offset_cost(node) } }
          latched ? @walker.in_fast_frame { each.call } : @walker.in_fast_interrupts { each.call }
        end

        # What keeping sprites out of a placed fade costs per frame, or nil when nothing is
        # kept out. The whole fade family is otherwise free — it tells the display what to
        # show and redraws nothing — so the one member that is not has to be named, or a
        # reader carries the wrong rule into the one place it stops holding.
        #
        # The console names each background layer separately and every sprite together, so
        # a line drawn among the sprites is bought with a second, invisible sprite over
        # each one that is kept: a table write a frame each, and a sprite slot. A fade that
        # keeps ALL the sprites needs none of that and stays free.
        def kept_sprites_verdict(program)
          layers = program.walk.filter_map { |node| node.under if node.kind == :fade }.uniq
          return nil if layers.empty?

          picture = Stacking.picture(program)
          kept = layers.flat_map { |layer| twinned_sprites(picture, layer) }.uniq
          return nil if kept.empty?

          # Charged in the frame's own body, because that is where it happens: the window
          # over a kept sprite is written in the same pass that writes the sprite, so it
          # runs from the same memory and gets the same discount.
          #
          # A window has a weight of its own, measured, and it is about four fifths of a
          # sprite write: it rides its sprite's numbers rather than working out its own, so
          # the frame copies each attribute on the way past and tests where the fade sits.
          cost = @walker.in_fast_frame { kept.length * @pricing.weight_here(:obj_window_write) }
          Verdict::KeptSprites.new(layers: layers, sprites: kept.length,
                                   cost: cost, budget: FRAME_BUDGET)
        end

        # The sprites a fade under +layer+ has to hold the effect off one at a time. None
        # when every sprite is on the kept side: the sprites then leave the blend's target
        # list together and it costs nothing.
        def twinned_sprites(picture, layer)
          kept = Stacking.at_or_above(picture, layer).map(&:name)
          keeps, blends = picture.objects.partition { |node| kept.include?(node.name) }
          blends.empty? ? [] : keeps.map(&:name)
        end

        def kept_sprites_cost(program)
          kept_sprites_verdict(program)&.cost || 0
        end

        # WHAT EACH DECLARED LAYER COSTS A FRAME, which is a different question from what
        # is inside it, and a different AXIS from the cost tree.
        #
        # The tree groups by the shape of the program — a case_var, a scene, a func, a
        # repeat — and answers "where in my code". A layer groups by depth in the picture
        # and answers "where on screen". A sprite in :actors inside scene :playing is in
        # both, so this is a roll-up printed beside the tree rather than a branch of it.
        #
        # What a depth costs is what the framework spends every frame on the things that
        # sit there, and that is a short list: presenting each sprite, moving a background
        # the game scrolls, and running a background's row-by-row bend. Everything else a
        # frame does — the game's own logic, its sound, drawing an author wrote out by
        # hand — sits at no depth at all. Most of a frame is usually that, which is why the
        # report prints the share as well as the numbers.
        #
        # The framework does all of it at the frame boundary, so the statements are read
        # from the frame's own body and never from inside a scene or a loop, where a cost
        # would have to be multiplied or a branch chosen.
        #
        # Every layer in the stack gets an answer, including the free ones. A tiled
        # background costs nothing once it is up however big it is, and a zero is the
        # thing worth seeing there.
        def layer_verdicts(program)
          picture = Stacking.picture(program)
          return [] if picture.stack.empty?

          layer_of = (picture.scenery + picture.objects).to_h { |node| [node.name, node.layer] }
          costs = Hash.new(0)
          @walker.in_fast_frame { tally_frame_layer_costs(costs, program, layer_of) }
          tally_bend_layer_costs(costs, program, layer_of)
          picture.stack.map { |name| Verdict::Layer.new(name: name, cost: costs[name]) }
        end

        # The per-frame upkeep the framework does for a thing with a depth. A name with no
        # layer lands under nil and is never read back — it is in no layer, and the share
        # the report prints is what says so.
        def tally_frame_layer_costs(costs, program, layer_of)
          @walker.steady_statements(program).each do |node|
            case node.kind
            when :present_objects
              share_out(costs, @pricing.op_cost(node),
                        node.names.to_h { |name| [name, @pricing.present_object_cost(name)] }, layer_of)
            when :scroll_background, :affine_background
              costs[layer_of[node.name]] += @pricing.op_cost(node)
            end
          end
        end

        # Split what one statement really cost among the depths it was spent at, in
        # proportion to what each thing in it takes.
        #
        # Sharing out the PRICED total rather than adding up raw weights is what keeps
        # this column and the cost tree agreeing. A statement is not the sum of its
        # weights — the quick-memory discount is applied to the statement, not to each
        # sprite in it — so adding weights up here gave a stack that cost more than the
        # whole frame. Whatever the pricing does to a statement lands here too, and the
        # parts still add back up to the whole.
        def share_out(costs, total, raw, layer_of)
          whole = raw.values.sum
          return if whole.zero?

          raw.each { |name, part| costs[layer_of[name]] += total * part / whole }
        end

        # A bend that no engine was free to feed is nearly all interrupt, and the display
        # raises that once a line however many backgrounds are bending — so it is one cost
        # shared among them rather than one each. Every real case bends a single background
        # and gets the whole figure either way.
        def tally_bend_layer_costs(costs, program, layer_of)
          bend = bend_verdict(program)
          return unless bend

          each = bend.cost / bend.layers.length
          bend.layers.each { |name| costs[layer_of[name]] += each }
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

        # What putting ONE row's offset in the table costs: the write itself, and the walk
        # that gets there. Two weights for the same reason again — this runs in the frame's
        # own body, which the build may have kept in the quick memory — and the copying
        # engine's own moment, which is in there too and gets no faster, is why it is not
        # the general factor.
        def bend_row_copied_weight
          @fast_frame ? @weights[:bend_row_copied_fast] : @weights[:bend_row_copied]
        end

        # What working ONE row's offset out costs: the program's expression, plus anything
        # it put in the block before it. The register write and the row bookkeeping are
        # already in the per-line weight.
        def bend_offset_cost(node)
          @pricing.expr_cost(node.offset) + node.children.sum { |child| @pricing.op_cost(child) }
        end

        # The bend's per-frame cost as a plain number (0 when nothing bends), for adding to
        # a frame the way the mixer's is.
        def bend_cost(program)
          bend_verdict(program)&.cost || 0
        end

        # What a timer's tick handler costs per frame, one entry per timer that runs one, or
        # nil when none does.
        #
        # A tick handler is the other place a program spends a frame outside its own loop.
        # `timer :beat, per_second: 4` runs its body four times a second whatever the frame
        # loop is doing; at 4000 a second it runs 67 times a frame, and then it is most of
        # the frame. Nothing about the statement it is written on says any of that — the rate
        # is on the `timer` that started it — so the cost is worked out for the whole frame
        # here and rolled in beside the mixer's and a bend's, the same way.
        #
        # Measured, the shape is the same as a bend's: the interrupt is the bigger half. One
        # tick costs 0.113 scanlines before the body does anything, which is about six plain
        # steps — so a body of one or two statements is mostly interrupt, and only a long
        # body outweighs it. Each entry: { timers:, cost:, budget:, over: }
        def tick_verdict(program)
          entries = program.walk.select { |node| node.kind == :on_timer }
                           .filter_map { |node| tick_entry(program, node) }
          return nil if entries.empty?

          cost = entries.sum(&:cost)
          Verdict::Ticks.new(timers: entries, cost: cost, budget: FRAME_BUDGET)
        end

        # One timer's share: how often it really ticks a frame, times the interrupt plus its
        # body. A handler on a timer that is never started has no rate and so no cost — it
        # never runs.
        def tick_entry(program, node)
          hz = timer_rate(program, node.timer)
          return nil unless hz

          each = tick_interrupt_weight + @walker.in_fast_interrupts { node.children.sum { |child| @walker.steady(child) } }
          delivered = deliverable_rate(hz, each)
          ticks = delivered / FULL_FRAME_RATE.to_f
          Verdict::Timer.new(name: node.timer, hz: hz, delivered: delivered, ticks: ticks,
                             each: each, interrupts: ticks * tick_interrupt_weight,
                             body: ticks * (each - tick_interrupt_weight), cost: ticks * each)
        end

        # HOW MANY OF THE TICKS ASKED FOR THE CONSOLE CAN ACTUALLY DELIVER, which is not
        # always all of them and is never more.
        #
        # A tick is an interrupt, and an interrupt that arrives while the last one is still
        # being answered is simply lost — there is no queue. So a handler that takes longer
        # than the gap between ticks misses every tick that lands inside it and catches the
        # next one after it finishes: at twice the gap it answers every second tick, at three
        # times it answers every third. The rate degrades in whole steps, and this is that
        # step.
        #
        # Measured on the console, a handler of eighty statements at 30,000 a second takes
        # about one and three quarter gaps and delivers exactly half the ticks; the same
        # handler at 4,000 fits inside its gap and delivers all of them. Priced at the rate
        # ASKED, the estimate read twice what the console spent, and the AUTHOR was told
        # nothing about getting half the ticks they wrote down (see the tick-rate guardrail).
        def deliverable_rate(hz, each)
          gap = FRAME_BUDGET * FULL_FRAME_RATE / hz.to_f # scanlines between two ticks
          hz / [(each / gap).ceil, 1].max
        end

        # How many times a second the named timer was started at.
        def timer_rate(program, name)
          program.walk.find { |node| node.kind == :timer_start && node.name == name }&.hz
        end

        # What one tick's interrupt costs — two weights, cartridge and faster memory, for
        # exactly the reason #bend_line_weight gives.
        def tick_interrupt_weight
          @fast_interrupts ? @weights[:tick_interrupt_fast] : @weights[:tick_interrupt]
        end

        # The tick handlers' per-frame cost as a plain number (0 when no timer runs one).
        def tick_cost(program)
          tick_verdict(program)&.cost || 0
        end

        # Everything a frame pays that the op tree cannot show, together: the sound mixer,
        # a row-by-row bend's per-line interrupt, a timer's tick handlers, and the sprites
        # a placed fade has to hold itself off. Add it to whichever reading of the tree is
        # being judged — everything on a frame, or only what recurs on every one.
        def standing_costs(program)
          mixer_cost(program) + bend_cost(program) + tick_cost(program) + kept_sprites_cost(program)
        end

        # What a frame spends inside the routine the console jumps into when the display or
        # a timer announces something — the number that decides whether that routine is
        # worth keeping in faster memory (Backends::GBA::Placement#IRQ_ROUTINE).
        #
        # Both things that can land there: bending backgrounds row by row, and timers' tick
        # handlers. A timer's whole cost is in that routine — the interrupt AND the body. A
        # bend's usually is not: in a paced program only the reading of one number per line
        # happens there, since the rows were worked out in the frame. In a program with no
        # frame the block runs there too, and then the bend counts in full.
        def interrupt_frame_cost(program)
          bend = bend_verdict(program)
          return tick_cost(program) unless bend

          in_the_irq = bend.interrupting + (Backends::GBA::BendForm.live?(program) ? bend.offsets : 0)
          in_the_irq + tick_cost(program)
        end

        # ...and the same question for the frame's OWN body, which is the other routine with
        # no name in the program. A bend's rows are worked out there, once a frame, and no
        # statement in the op tree says so — so a body that is nothing but a bend would read
        # as idle and lose the room to something that matters less.
        #
        # WHAT THE FRAME BOUNDARY COSTS IS LEFT OUT, because this answer decides whether the
        # body is worth quick memory and the boundary cannot get any faster there: waiting for
        # the screen is the console's own doing and takes the same time wherever our code
        # lives. It is also several times Placement::WORTH_MOVING on its own, so counting it
        # would put every looping program over that bar and the bar would decide nothing.
        def frame_body_cost(program)
          body = @walker.steady_cost(program) - frame_boundary_cost(program)
          bend = bend_verdict(program)
          return body unless bend && Backends::GBA::BendForm.latched?(program)

          body + bend.filling + bend.offsets
        end

        # What the walk above charged for the frame's boundary, so it can be taken back out.
        #
        # THE BUTTON LATCH STAYS IN, though the walk charges it at the boundary too (see
        # Pricing#wait_cost). It is ten of our own instructions, and unlike the BIOS asleep
        # they run faster from the quick memory — so they are part of what moving the body
        # there would buy, which is the question this answer decides.
        def frame_boundary_cost(program)
          waits = @walker.steady_statements(program).count { |node| node.kind == :wait_vblank }
          waits * @weights[:frame_overhead]
        end

        # The rate the mixer runs at — the one most of the program's samples were recorded
        # at (matching the backend), so the buffer size is right. Defaults when none say.
        def mixer_rate(program)
          rates = program.walk.select { |node| node.kind == :sample }.filter_map { |node| node.rate }
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
          program.walk { |node| audit_price(node) }
          @pricing.unpriced.dup
        end

        # The kinds this program uses that the model prices to something that is not a
        # number at all — an Infinity, or a NaN. Empty for every program that works.
        #
        # WHY THIS IS ASKED AT ALL, because "the arithmetic went wrong" is not usually
        # something a report checks for itself. A frame total made of a NaN is not merely
        # wrong: every comparison against a NaN answers false, so the over-budget test says
        # no, the tearing test says no, and a broken estimate reads exactly like a game that
        # comfortably fits. It is the one failure this model can turn into silent, confident
        # approval, so it is worth a walk to catch.
        def nonsense_kinds(program)
          found = []
          program.walk do |node|
            cost = audit_price(node)
            found << node.kind unless cost.nil? || cost.to_f.finite?
          end
          found.uniq
        end

        # Price one node for no reason but to find out whether the model knows how.
        # Control flow is skipped: it is costed by walking what it contains, never priced
        # on its own, so asking it would flag every `if` in the program.
        def audit_price(node)
          case node.category
          when :value then @pricing.expr_cost(node)
          when :root, :control then nil
          else @pricing.op_cost(node) # a statement — including a kind the table has never heard of
          end
        end

        # HOW MUCH OF THE MEASURED FRAME THE BREAKDOWN ACCOUNTS FOR, when a measurement
        # ran — the estimate's own coverage, checked against the one number that cannot be
        # argued with.
        #
        # The report has always put an estimated TREE next to a measured TOTAL and never
        # related the two, and that is a blind spot with no bottom to it. When a cost is
        # missing from the model, BOTH halves still look fine: the tree sums to something
        # plausible, the verdict reads correct because it is measured, and nothing anywhere
        # looks odd. A timer's tick handler cost nothing for as long as it did for exactly
        # that reason — the estimate said 0, the emulator said 9 scanlines, and the two sat
        # four lines apart in the same report.
        #
        # This is a beat in the loop the whole tool exists for: guess where the frame goes,
        # look, find out you were wrong. Before an author optimizes the biggest line in the
        # breakdown, they get told whether the breakdown is the whole frame.
        #
        # Returns nil when there is nothing to say, or { estimate:, measured:, share:,
        # blind: }.
        def residual_note(program, measured)
          return nil unless measured && looping?(program)

          estimate = @tree.category_tree(program).sum(&:cost)
          # The tree is the heaviest frame the program can reach and the reading is the
          # worst frame found, so they answer the same question. Across scenes, take the
          # dearest — the tree costs a case_var at its heaviest branch too.
          worst = measured.values.filter_map { |result| result[:scanlines] }.max
          return nil unless worst&.positive?
          return nil if estimate > worst * RESIDUAL_SHARE || worst - estimate < RESIDUAL_GAP

          { estimate: estimate, measured: worst, share: estimate / worst,
            blind: estimate_blind_spots(program) }
        end

        # A loud line, above the estimate, when the breakdown accounts for far less of the
        # frame than the emulator measured.
        #
        # It says the share is a NET and that is not a hedge, it is the arithmetic. The
        # estimate is deliberately not a point prediction: it counts a list walk and a pool's
        # bodies at what those usually hold, counts a `pressed` body at zero, and holds the
        # collision worst case out of the recurring load. An over-count and an under-count
        # land in the same total, so a program can read 100% with two real errors in it that
        # happen to cancel. A LOW share is strong evidence of a problem; a high one is weak
        # evidence of correctness, and saying only the first half would mislead.
        #
        # IT IS RED, like the other two banners, and that does not break the rule that red
        # means a frame is over budget. A banner sits ABOVE the report and is a statement
        # about the report, not about the game: the verdict line below keeps its own colour,
        # so a game that fits in a frame still reads green where it counts. All three
        # banners say the same thing — do not act on the breakdown below — and an author who
        # spends an afternoon optimizing the biggest line in a breakdown that is missing the
        # real cost has been failed exactly as badly as one whose frame overran.
        def emit_residual_banner(printer, program, measured)
          note = residual_note(program, measured) or return

          missing =
            if note[:blind].any?
              "The estimate cannot price #{note[:blind].join(' or ')}."
            else
              "Some of this frame is not priced."
            end
          printer.puts "!! the breakdown accounts for #{CostModel.pct(note[:estimate], note[:measured])} of the " \
                       "measured frame (~#{CostModel.fmt(note[:estimate])} of ~#{CostModel.fmt(note[:measured])} scanlines). " \
                       "#{missing} So the largest line below is not always the largest cost. The share " \
                       "is a net: an over-count and an under-count can cancel. So a low share shows a " \
                       "problem, but a high share does not show that there is none.", emphasis: :banner
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

        # ...and the louder one: a price that is not a number. This is a fault in the cost
        # model rather than anything the author did, so it says so — an author who reads
        # "cannot estimate" about their own game goes looking for the mistake in their game.
        def emit_nonsense_banner(printer, program)
          kinds = nonsense_kinds(program)
          return if kinds.empty?

          printer.puts "!! the estimate for #{kinds.sort.join(', ')} is not a number, so this report " \
                       "cannot say whether the frame fits. This is a fault in the cost model. Your " \
                       "game is not the cause of it.", emphasis: :banner
        end

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
          mixer_verdict(program)&.cost || 0
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
          measured = "measured ~#{CostModel.fmt(result[:scanlines])} of #{FRAME_BUDGET} scanlines " \
                     "(#{CostModel.pct(result[:scanlines], FRAME_BUDGET)})"
          return "#{measured}#{held}#{usual_frame_suffix(result)}" unless result[:saturated]
          return "#{measured}#{held} — still #{FULL_FRAME_RATE} fps" if holds_full_rate?(result)

          # OVER BUDGET STILL GETS A NUMBER, and it has to. The per-FRAME reading above stops at
          # the ceiling once a pass spreads across two frames, so on its own it cannot tell a
          # game that got a third faster from one that did not move — which is exactly the
          # question somebody reading this line is asking. What a whole PASS cost has no
          # ceiling, so that is what is reported here, in the same scanlines the budget is in.
          if result[:per_pass]
            over = "measured ~#{CostModel.fmt(result[:per_pass])} of #{FRAME_BUDGET} scanlines " \
                   "(#{CostModel.pct(result[:per_pass], FRAME_BUDGET)}) a pass"
            return "#{over}#{held} — running at ~#{result[:fps]} fps" if result[:fps]

            return "#{over}#{held}"
          end
          return "measured over budget — running at ~#{result[:fps]} fps#{held}" if result[:fps]

          "measured over budget#{held} — the frame saturates (drops frames)"
        end

        # ...AND WHAT A FRAME USUALLY COSTS, said only when that is a different question.
        #
        # The number above is the WORST frame, which is what a budget is about: a frame that
        # does not fit is a frame that tears, however rare it is. But a game with work that
        # only happens sometimes — a collision that walks when two sprites really touch, a
        # board redrawn on a beat — pays that on a few frames and something far smaller on the
        # rest. A reader holding the worst frame against the "every frame" line above would
        # then think the estimate badly wrong when it is right: examples/pacman.rb measures 4.1
        # at its worst and 2.5 the rest of the time, against an estimate of 2.6.
        #
        # Nothing is said when the two agree, so a game whose frame is the same every time is
        # not told the same number twice.
        # How much cheaper the usual frame has to be before it is worth a second number.
        #
        # MEASURED ON THE CORPUS RATHER THAN PICKED. The examples fall into two groups with an
        # empty band between them: the ones holding rare work run from 0.60 to 0.87 of their
        # worst frame (pacman 0.60, shmup 0.64, animate 0.72, piano 0.79, breakout 0.87), and
        # every other one is 0.94 or above. A tenth sits in the gap.
        #
        # It is a decision about what to PRINT, so being a little wrong costs one line either
        # way and nothing else — which is why a corpus of twenty-four is enough to settle it.
        NOTICEABLY_CHEAPER = 0.9

        def usual_frame_suffix(result)
          usual = result[:typical] or return ""
          return "" unless usual < result[:scanlines] * NOTICEABLY_CHEAPER

          " — a usual frame ~#{CostModel.fmt(usual)}"
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

        # WHAT EVERY WALK OVER A LIST WAS COUNTED AT — one entry per list walked, as
        # { name:, counted:, capacity:, said: }.
        #
        # The every-frame figure rests on this and can rest on nothing else: a walk is
        # bounded by the list's capacity, that is the only number a build can prove, and it
        # is nearly always far above what the list really holds. So the number used is
        # either what the author said (`estimate: { usually: 12 }`) or a guess, and the
        # report says which.
        def list_walk_verdicts(program)
          walks = program.walk.filter_map do |node|
            next unless node.kind == :repeat

            count = node.count
            next unless count.is_a?(Node) && count.kind == :list_len && @catalogue.capacities[count.name]

            Verdict::ListLength.new(name: count.name, counted: @walker.list_length(count.name),
                                    capacity: @catalogue.capacities[count.name],
                                    said: @catalogue.list_lengths.key?(count.name))
          end
          walks.uniq(&:name)
        end

        # WHAT EVERY WALK OVER A SET OF SLOTS COUNTED AS IN USE — one entry per set walked,
        # as { name:, counted:, slots:, said: }.
        #
        # The sibling of the line above, and the difference is what is being counted. A list
        # walk goes round as many times as the list is long, so the LENGTH decides the passes.
        # A pool's walk goes round for every slot however few are live — those passes are real
        # and are counted whole — and what the guess decides is how many times the BODY runs.
        def live_slot_verdicts(program)
          guards = program.walk.filter_map do |node|
            next unless node.kind == :if && node.of

            Verdict::LiveSlots.new(name: node.over, counted: node.usually || @walker.unsaid_share(node.of),
                                   slots: node.of, said: !node.usually.nil?)
          end
          guards.uniq(&:name)
        end

        # WHAT EVERY LOOP THAT CAN STOP EARLY WAS COUNTED AT — one entry per such loop, as
        # { counted:, ceiling:, said: }.
        #
        # The third of these, and the one that can be furthest out. A ceiling is picked so it
        # can never be reached, and this kind of loop is usually inside another one, so the
        # over-count multiplies: a ray that gives up after forty-eight crossings meets a wall
        # in a handful, and eighty rays make that the whole frame.
        def early_exit_verdicts(program)
          program.walk.filter_map do |node|
            next unless node.kind == :repeat && @walker.stops_early?(node)

            count = node.count
            ceiling = count.is_a?(Node) && count.kind == :int ? count.value : nil
            Verdict::EarlyExit.new(counted: node.usually || (ceiling && @walker.unsaid_share(ceiling)) || 0,
                                   ceiling: ceiling, said: !node.usually.nil?)
          end
        end

        # HOW TALL EACH STRETCHED COLUMN WAS COUNTED AT. A height the game works out is what
        # perspective produces, so this is every column of a first-person view — the most
        # expensive thing such a game does, and the one the estimate used to count as nothing at
        # all. It has a ceiling where most computed sizes do not (a column is clipped), so it can
        # be guessed rather than skipped, and the guess is worth saying out loud.
        # BOTH VERBS ANSWER HERE, because both are ways to write the same wall: a column of a
        # picture stretched to fit, or a plain rectangle as tall as the distance says. A game
        # picks one and the reader wants the same line either way.
        def stretched_column_verdicts(program)
          program.walk.filter_map do |node|
            height = STRETCHED_HEIGHT[node.kind] or next
            height = node.public_send(height)
            next if height.is_a?(Node) && height.kind == :int
            # A rectangle with no provable WIDTH is charged nothing at all, so no height was
            # guessed for it and saying one would contradict the line that says it was not
            # counted. Two notes about the same rectangle, one of them untrue.
            next if @pricing.runtime_sized_rect?(node)

            ceiling = column_ceiling_for(node)
            Verdict::StretchedColumn.new(name: node.kind == :draw_column_at ? node.name : nil,
                                         counted: node.usually || (ceiling / 2),
                                         ceiling: ceiling, said: !node.usually.nil?)
          end
        end

        # The shapes that can be stretched to a height the game works out, and what each calls
        # that height.
        STRETCHED_HEIGHT = { draw_column_at: :height, draw_rect_at: :h }.freeze

        # Fewer rectangles a frame than this and a column is a thing that moves, not a grid —
        # a ball, a ship — and a freely moving thing cannot have an even column and must not
        # be pushed toward one. The note is for the grid case only.
        MANY_RECTANGLES = 8

        # ...and below this share of the every-frame figure the column is not where the frame
        # goes, whatever its ratio, so nothing is said.
        ODD_COLUMN_WORTH_SAYING = 0.05

        # RECTANGLES AT AN ODD COLUMN on the tear-free screen, one entry per source line, for
        # the note that says so. That screen holds two pixels in one unit, so a row that starts
        # halfway through a unit is spliced at both ends and costs about three times a row
        # that does not — and the author, who wrote `cell * 7`, has no way to know. Only the
        # grid case (many a frame, a real share of the frame) is reported; a lone moving
        # rectangle is what it is. +leaves+ are the tree's weighed leaves, which is where how
        # many times a frame each draw runs is known (see Tree.weigh_leaves).
        def odd_column_verdicts(program, leaves)
          return [] unless buffered?(program) && !mixed?(program)

          recurring = @walker.steady_cost(program) + standing_costs(program)
          leaves.select { |leaf, _times| leaf.op == :draw_rect_at && leaf.source }
                .group_by { |leaf, _times| leaf.source }
                .filter_map { |source, rows| odd_column_verdict(program, source, rows, recurring) }
        end

        def odd_column_verdict(program, source, rows, recurring)
          nodes = program.walk.select { |node| node.kind == :draw_rect_at && node.source == source }
          moving = nodes.select { |node| @pricing.even_column_cost(node) }
          return nil if moving.empty?

          parities = moving.map { |node| Parity.of(node.x) }
          return nil if parities.all?(:even)

          draws = rows.sum { |leaf, times| (leaf.count || 1) * times }
          cost = rows.sum { |leaf, times| leaf.cost * times }
          return nil if draws < MANY_RECTANGLES || cost < ODD_COLUMN_WORTH_SAYING * recurring

          sample = moving.first
          even_share = @pricing.even_column_cost(sample) / @pricing.tearfree_moving_rect_cost(sample)
          Verdict::OddColumn.new(source: source, proved_odd: parities.all?(:odd), draws: draws.round,
                                 cost: cost, even_cost: cost * even_share)
        end

        # The most rows this column could walk: the height of the part of the screen it is being
        # drawn into, since it is clipped to that, or the whole screen where it is in no area.
        # Found by looking up rather than down, because the walk here is flat.
        #
        # A column inside a ROUTINE called from an area reads the whole screen, because a
        # routine's body is not written inside the area — the area is in force when it is
        # CALLED. That makes the ceiling generous rather than wrong, and the author can say the
        # height where it matters.
        def column_ceiling_for(node)
          at = node.parent
          while at
            return @pricing.const_side(at.h) || IR::Screen::HEIGHT if at.kind == :inside

            at = at.parent
          end
          IR::Screen::HEIGHT
        end

        # Whether the program has a repeat whose trip count has no provable bound — not a
        # literal, not a capacity-bounded list — so the estimate counts its body as zero.
        def unbounded_loop?(program)
          program.walk.any? { |node| node.kind == :repeat && @walker.repeat_factor(node).last.include?("unbounded") }
        end

        # Whether the program fills a rectangle whose width or height it works out as it
        # runs. The estimate counts that fill as zero for the same reason it counts an
        # unbounded loop as zero — there is no provable size to charge for.
        def runtime_sized_rect_anywhere?(program)
          program.walk.any? { |node| @pricing.runtime_sized_rect?(node) }
        end
      end
    end
  end
end

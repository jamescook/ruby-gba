# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Which routines run from the console's quick memory, and how they get there.
        #
        # THE HARDWARE, briefly. Code lives in the cartridge, which the console reads over a
        # narrow, slow connection. It also has 32KB of memory of its own that runs at full
        # speed with nothing to wait for. Nothing decides which one a routine runs from
        # except where its bytes happen to be — so a routine can be made faster by copying it
        # into the quick memory at boot and jumping there instead.
        #
        # HOW MUCH FASTER, since that is the number everything here turns on: about two and a
        # half times, comparing THE SAME INSTRUCTIONS in the two places they can live. Not an
        # algorithm being improved — identical code, in identical order, fetched over the
        # cartridge connection or out of the console's own memory. It is measured rather than
        # reasoned about, on a body of plain arithmetic steps so that nothing but the fetching
        # differs (tools/calibration/calibrator.rb#fast_memory), and it is the weight the cost
        # model calls fast_code_speedup.
        #
        # It is not free. There is only 32KB and it is already home to every variable,
        # every list, the sound mixer's working memory and the stack. So this is a
        # choosing problem, and what it chooses has to be visible and overridable — which
        # is what the rest of this file is about.
        #
        # HOW THE CHOOSING WORKS. The cost model already knows what a frame spends where,
        # so the ranking is simply: the routine a frame spends most time in goes first,
        # then the next, until the room runs out. Sizes are not known until the code is
        # emitted, so the build lowers the program ONCE with nothing moved, reads off how
        # big each routine came out and how much memory the variables took, and then
        # lowers it for real. The throwaway pass is why this can be an informed choice
        # rather than a guess.
        #
        # An author can always overrule it — `func :name, fast: true` or `fast: false`,
        # and `fast_code: false` on the build turns the choosing off entirely without
        # taking the per-routine switch away.
        #
        # WHAT MOVING A ROUTINE COSTS AT THE CALL SITE. A jump straight to a label reaches
        # 32MB; the quick memory is 80MB away from the cartridge. So a call that CROSSES
        # between the two has to build the address in a register and jump through it —
        # four instructions instead of one. A call that stays on one side is untouched,
        # and since the moved routines are copied as ONE block their distances from each
        # other are preserved, so they call each other exactly as they did before.
        module Placement
          include Constants

          # The block of moved routines sits between these two labels in the cartridge,
          # which is where boot copies it from.
          HOT_START = :__hot_code
          HOT_END = :__hot_code_end

          # The game loop's body, treated as a routine so it can be placed like one. It
          # is not a routine the author wrote — a game loop's body is just statements —
          # but it is where nearly all of a frame's time is spent, so it is the single
          # most valuable thing to move, and pretending it is a routine is what lets the
          # same choosing and the same report cover it. Measured on examples/raycaster.rb,
          # which has no routines at all: 191 scanlines a frame down to 69.
          FRAME_ROUTINE = :__frame

          # The routine the console jumps into when the display or a timer announces
          # something. Like the game loop's body it is not a routine the author wrote, but
          # it is a routine in every way that matters here, so it is placed like one.
          #
          # It earns its place the same way anything else does — by what a frame spends in
          # it. That is usually nothing: a program that only sleeps until the next frame
          # enters it once a frame and leaves again immediately. But a background bending
          # row by row with no copying engine left to feed it is entered after every single
          # line the display draws, 228 times a frame, and then it is the busiest routine in
          # the program by a wide margin. (Where an engine does the feeding this lands here
          # not at all — see {BendForm} — and then the routine is worth nothing again and
          # the room goes to the frame's own body, which is where that bend's table is
          # filled.)
          #
          # It buys less than the 2.6x the rest of this file talks about — 1.9x, measured —
          # because a fair share of an interrupt is the console's own doing, and that part
          # runs wherever the console keeps it however fast our memory is.
          IRQ_ROUTINE = :__interrupt

          # The top of the memory the moved block may use. The last 4KB is where the
          # divide routines are copied and where the console's own startup code keeps its
          # stack, so nothing of ours may grow into it.
          HOT_CEILING = IWRAM_START + IWRAM_SIZE - 0x1000

          # A routine has to earn its place: below this many scanlines a frame, moving it
          # saves less than the four instructions each of its call sites now costs. It
          # also stops a program with no hot loop at all from filling the quick memory
          # with routines that run once.
          WORTH_MOVING = 0.05

          # THE FRAMEWORK KEEPS NOTHING BACK when it is choosing on its own, and the reason
          # is worth writing down because there used to be a kilobyte held here and its
          # comment said it was for tidiness.
          #
          # It was not for tidiness. It was quietly covering an under-estimate in
          # #moved_sizes, which counted the crossing calls an author WROTE and missed the
          # ones the lowering invents for run-time digits. With that fixed the size a
          # routine is charged is a true upper bound, so a kilobyte held back is a
          # kilobyte of pure loss — and it was landing on exactly the routine that could
          # least afford it. Measured on games/wolf3d, whose game loop wanted 21.6K of a
          # 21.6K space and was offered 20.6K: it missed by the width of the margin, and
          # the whole frame ran from the cartridge at about a third of the speed.
          #
          # If the bound is ever wrong again the build stops with the message in
          # #guard_fast_code_fits, which names the overrun and what to do about it. A loud
          # failure that points at the real fault beats a silent margin that pays for it
          # for ever.

          # A call from a moved routine to one still in the cartridge grows, so a routine
          # can come out bigger than it measured. This is the most any one call can add.
          #
          # COUNT IT OFF THE EMITTER RATHER THAN OFF THE SENTENCE "one instruction to
          # four", which is what this used to say and what made it wrong. A plain call is
          # a four-byte branch. A crossing one is #emit_call_func's other arm: the target
          # address built by a FIXED-SIZE immediate (four instructions, always, because a
          # two-pass fixup has to patch a slot it cannot resize), then a move and a jump
          # through it — sixteen plus four plus four. So it grows by twenty.
          #
          # Being short here does not fail loudly at the call. It fails at the very end,
          # in #guard_fast_code_fits, on a game that fits: the chooser adds up sizes that
          # are each a little under, takes one routine more than there is room for, and
          # the build stops with advice about a routine the author would have to guess at.
          # Twelve was under by eight a call, which was worth 224 bytes on one routine of
          # games/wolf3d alone.
          CROSS_CALL_GROWTH = 20

          # Saving the return address on the way in and returning at the end. The game
          # loop's body measures without these, because inline it needs neither.
          ROUTINE_WRAPPER = 8

          # Names of the routines that will run from the quick memory. Valid after #lower.
          def fast_funcs = @fast_funcs.dup

          # Where the moved block ended up and how big it is, for the report. nil when
          # nothing moved.
          attr_reader :hot_base, :hot_bytes

          # How much of the quick memory this build used, and what is left — the numbers
          # `rom.profile` prints. The field names are ours, fixed when this is written, so it
          # is a value object: a reader asking for a field that is not here says so instead of
          # answering nil and printing a blank number.
          # +sizes+ is how many bytes each routine came to, whether it moved or not, and
          # +passed_over+ is the routines the chooser WANTED and could not fit, each with what
          # it would have taken and what was left. That second one is the actionable half: a
          # routine that just missed is where a program lost the whole factor above, and
          # nothing else in the build can say so afterwards.
          # +chosen_from+ says which of the two answers decided the list: :measurement when a
          # profile of a real run was handed to the build, :shape when there was none and the
          # order came from what the frame can reach. It is on the report because the
          # difference is the difference between a tuned game and an untuned one, and an
          # author cannot tell by looking at the numbers.
          Report = Data.define(:funcs, :code_bytes, :used_bytes, :free_bytes, :total_bytes,
                               :sizes, :passed_over, :chosen_from) do
            def initialize(chosen_from: :shape, **rest) = super
          end

          # A routine the chooser skipped, and by how much.
          PassedOver = Data.define(:name, :bytes, :room)

          # Valid after #lower.
          def iwram_report
            Report.new(funcs: @fast_funcs.to_a,
                       code_bytes: @hot_bytes.to_i,
                       used_bytes: @memory.used,
                       free_bytes: @memory.free,
                       total_bytes: IWRAM_SIZE,
                       sizes: @routine_sizes || {},
                       passed_over: @passed_over || [],
                       chosen_from: @routine_profile ? :measurement : :shape)
          end

          # Decide what moves. Runs before anything is emitted, and answers a set of func
          # names — empty when there is nothing worth moving or the author turned it off.
          def choose_fast_funcs(program)
            insisted = funcs_marked(program, true)
            return insisted if insisted.empty? && !@fast_code

            # The probe reports through the same object this one does, so the measuring pass
            # shows its own progress rather than going quiet for as long as a lowering takes.
            @progress.step("measuring the routines")
            probe = self.class.new(fast_cartridge: @fast_cartridge, progress: @progress)
            probe.lower(program, fast_funcs: Set.new) # measure the program with nothing moved
            sizes = moved_sizes(program, probe.func_sizes)
            # Every allocation is rounded up to a whole word, so the gap the probe leaves is
            # the gap there really is — there is no alignment slop to keep back for.
            room = probe.iwram_free

            # Kept for the report: what each routine came to, and what a reader will want to
            # know afterwards is why theirs is not on the list.
            @routine_sizes = sizes
            @passed_over = []

            chosen = Set.new
            room = place_insisted(program, insisted, sizes, room, chosen)
            place_by_frame_cost(program, sizes, room, chosen) if @fast_code
            chosen
          end

          # The memory address a func runs from once the program is lowered — its place in
          # the moved block, or nil if it stayed in the cartridge. Used to resolve a call
          # that crosses between the two.
          def fast_func_address(name)
            return nil unless @fast_funcs.include?(name)

            @hot_base + (@emit.labels.fetch(@functions.func_label(name)) - @emit.labels.fetch(HOT_START))
          end

          # What the variables at one end and the lists and buffers at the other have
          # left between them. Read off the throwaway pass to know how much room there
          # is for code.
          def iwram_free = @memory.free

          # Each func's size in bytes, likewise read off the throwaway pass.
          def func_sizes
            @functions.func_ranges.transform_values(&:size)
          end

          # Once the game loop's body is going to the quick memory it needs a name and a
          # place in the routine table, so that everything downstream — emitting it,
          # calling it, reporting it — treats it as the routine it has become. Its "body"
          # is the loop node's own statements.
          def adopt_frame_body(program)
            return unless @fast_funcs.include?(FRAME_ROUTINE)

            loop_node = program.walk.find { |node| node.kind == :loop }
            @functions.funcs[FRAME_ROUTINE] = loop_node if loop_node
          end

          # Emit the moved routines, back to back, between the two labels boot copies
          # between. One block, not several, so their distances from each other survive
          # the copy and they go on calling each other with a plain jump.
          def emit_hot_functions
            return if @fast_funcs.empty?

            emit(ASM.loop_forever) # fall-through guard, outside the block so it is not copied
            place_label(HOT_START)
            @emitting_hot = true
            @functions.funcs.each { |name, node| @functions.emit_one_function(name, node) if @fast_funcs.include?(name) }
            emit_irq_handler if irq_runs_fast?
            @emitting_hot = false
            place_label(HOT_END)
          end

          # Does the routine the console interrupts into run from the quick memory this
          # build? When it does, it is emitted inside the moved block above and the vector
          # is pointed at where the block lands rather than at the cartridge.
          def irq_runs_fast?
            uses_irq? && @fast_funcs.include?(IRQ_ROUTINE)
          end

          # Give the moved block its home: the first spare word above everything else in
          # the quick memory. Nothing may be given an address there afterwards.
          def place_hot_code
            return if @fast_funcs.empty?

            # The copy moves whole words, and every allocation is rounded up to one, so
            # what comes back is already on a word.
            @hot_bytes = @emit.labels.fetch(HOT_END) - @emit.labels.fetch(HOT_START)
            @hot_base = @memory.alloc(@hot_bytes)
            guard_fast_code_fits
          end

          # What each moved routine was CHARGED against what it came out at, for the one
          # test that can tell whether #moved_sizes is still the upper bound it claims to
          # be (a charge that is short does not fail here — it fails much later, in
          # #guard_fast_code_fits, on a game that fits). Valid after #lower.
          def charged_against_emitted
            @fast_funcs.to_h do |name|
              [name, [(@routine_sizes || {})[name].to_i, @functions.func_ranges[name]&.size.to_i]]
            end
          end

          # Copy the block from the cartridge into the quick memory, once, at boot.
          #
          # By the transfer engine rather than an instruction at a time, and the difference
          # matters more than it looks: a whole game's loop can be twenty thousand bytes,
          # and reading those a word at a time — from the cartridge, which is the slow
          # thing this whole file exists to avoid — took nearly half a frame before the
          # game had drawn anything. The engine does the same copy in a fraction of that.
          # (The divide routines are copied the slow way still; they are a few hundred
          # bytes and it does not show.)
          def emit_copy_hot_code_to_iwram
            emit_load_label_address(ACC, HOT_START)
            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(ACC, TMP))              # source = the block, in the cartridge
            emit_load_fast_address(ACC, HOT_START)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(ACC, TMP))              # destination = where it is going
            @emit.fixups << { pos: pos, kind: :hot_size, reg: ACC }
            emit(ASM.load_immediate_fixed(ACC, 0)) # ...and how much, patched once it is known
            emit(ASM.load_immediate(TMP, REG_DMA3CNT))
            emit(ASM.str(ACC, TMP))
          end

          # Patch in the transfer's size and start it: whole words, both ends advancing.
          # A custom fixup kind #resolve_fixups doesn't know about — Emit hands it here
          # via the resolver map GBA#lower builds (see GBA#lower).
          def resolve_hot_size(fix)
            words = @hot_bytes / 4
            @emit.patch16(fix[:pos], ASM.load_immediate_fixed(fix[:reg], words | DMA_32BIT | DMA_ENABLE))
          end

          # Call a routine. A call that stays on one side of the cartridge/quick-memory
          # line is the plain jump it always was; one that crosses has to build the
          # address and jump through it, because the two are far too far apart for a jump
          # to reach.
          def emit_call_func(name)
            target_is_fast = @fast_funcs.include?(name)
            return emit_branch(:bl, @functions.func_label(name)) if target_is_fast == @emitting_hot

            if target_is_fast
              emit_load_fast_address(ADDR, @functions.func_label(name))
            else
              emit_load_label_address(ADDR, @functions.func_label(name))
            end
            emit_call_through(ADDR)
          end

          # Call a routine that never itself moves to the quick memory — always in the
          # cartridge, whichever call reaches it. Digit routines are the one caller
          # (see Drawing#emit_digit_routines): plain when the call is cold too, and
          # the same address-and-jump-through #emit_call_func's own crossing call
          # uses when the call is running from inside the moved block, since a label
          # back in the cartridge is too far from the quick memory for a relative
          # branch to reach.
          def emit_call_cold_routine(label)
            return emit_branch(:bl, label) unless @emitting_hot

            emit_load_label_address(ADDR, label)
            emit_call_through(ADDR)
          end

          # Load the quick-memory address of a label inside the moved block. Where the
          # block lands is not known until every variable has one, so this is a
          # fixed-size placeholder patched in the second pass — the same trick a
          # reference to embedded data uses.
          def emit_load_fast_address(reg, label)
            @emit.fixups << { pos: pos, kind: :fast_addr, reg: reg, target: label }
            emit(ASM.load_immediate_fixed(reg, 0))
          end

          # Also a custom fixup kind, handed to Emit's resolver map the same way
          # #resolve_hot_size is.
          def resolve_fast_address(fix)
            offset = @emit.labels.fetch(fix[:target]) - @emit.labels.fetch(HOT_START)
            @emit.patch16(fix[:pos], ASM.load_immediate_fixed(fix[:reg], @hot_base + offset))
          end

          private

          # The quick memory is 32KB and everything shares it. Growing past what is left
          # would quietly overwrite the console's own startup stack, so say so instead,
          # and say what to do about it.
          def guard_fast_code_fits
            over = @memory.overrun
            return if over.zero?

            raise LoweringError,
                  "this program needs #{@memory.used} bytes of the console's quick memory, " \
                  "which is #{over} more than there is. #{@hot_bytes} of it is routines kept there to " \
                  "run faster. To fix this, mark a routine `func :name, fast: false` to leave it in the " \
                  "cartridge, or build with `fast_code: false` to keep them all there."
          end

          # The routines the author named one way or the other. `fast: true` is taken as
          # an instruction and is placed before anything the framework picked; `fast:
          # false` is taken as an instruction too and is never picked.
          def funcs_marked(program, want)
            program.walk.select { |node| node.kind == :func && node.fast == want }
                   .map { |node| node.name }.to_set
          end

          # How big each routine will be once moved. A routine measured in the throwaway
          # pass can only grow, and only in one way — every call it makes to a routine left
          # behind grows by CROSS_CALL_GROWTH — so charging it for ALL of its calls is an
          # upper bound. Being a little pessimistic here means the last routine chosen might
          # have fitted after all; being optimistic would mean a build that overruns the
          # memory, so this is the direction to be wrong in.
          #
          # NOT EVERY CROSSING CALL IS A `call` THE AUTHOR WROTE, and each kind that was
          # missed made this an under-estimate rather than an upper bound. Two are invented
          # by the lowering, with no `call` node anywhere to show for them:
          #
          # A RUN-TIME DIGIT shares one glyph-drawing routine per font and calls it, so every
          # `draw_digit` is a crossing call. A game with a score on screen has one per digit
          # place, which came to a couple of hundred bytes in examples/breakout.rb.
          #
          # A MULTI-WAY DISPATCH calls the scene it lands on, one call per clause, built out
          # of `call` nodes made while emitting rather than nodes the tree holds (see
          # Functions#emit_case). That is a game's whole scene table — and it lands on the
          # game loop's own body, which is the routine that can least afford to be
          # mismeasured, because it is the first one the chooser takes.
          CROSSING_CALL_KINDS = %i[call draw_digit].freeze

          # ...and a dispatch, whose calls are one per clause rather than one per node.
          def dispatch_calls_in(node)
            node.walk.select { |child| child.kind == :case }.sum { |child| child.clauses.length }
          end

          def moved_sizes(program, measured)
            calls = Hash.new(0)
            program.walk.each do |node|
              name = node.kind == :loop ? FRAME_ROUTINE : (node.name if node.kind == :func)
              calls[name] = crossing_calls_in(node) if name
            end
            calls[IRQ_ROUTINE] = irq_bodies(program).sum { |node| crossing_calls_in(node) }
            measured.to_h do |name, size|
              [name, size + (calls[name] * CROSS_CALL_GROWTH) + ROUTINE_WRAPPER]
            end
          end

          def crossing_calls_in(node)
            node.walk.count { |child| CROSSING_CALL_KINDS.include?(child.kind) } +
              dispatch_calls_in(node)
          end

          # The trees the console runs on an announcement: every bending background's block
          # and every timer's tick body. There is no one node standing for all of it the way
          # a routine has one, so the pieces are gathered.
          #
          # A bend in a paced program is not among them: its block runs in the frame like
          # ordinary code, into a table, and what the announcement then does is read one
          # number out of it (see {BendForm}).
          def irq_bodies(program)
            kinds = BendForm.live?(program) ? %i[scroll_rows on_timer] : %i[on_timer]
            program.walk.select { |node| kinds.include?(node.kind) }
          end

          # The routines the author asked for by name, placed before anything the
          # framework picked and not held to its share of the room. Answers what is left.
          def place_insisted(program, insisted, sizes, room, chosen)
            movable = program.walk.select { |node| node.kind == :func && insisted.include?(node.name) }
            movable.each do |node|
              name = node.name
              guard_insisted_fits!(name, sizes[name], room)
              chosen << name
              room -= sizes[name]
            end
            room
          end

          # Then whatever a frame spends the most time in, biggest earner first, within
          # the framework's own share. Anything that will not fit is skipped rather than
          # stopping the fill — a small routine after a large one still gets its chance.
          def place_by_frame_cost(program, sizes, room, chosen)
            forbidden = funcs_marked(program, false)
            ranked = ranked_by_frame_cost(program, sizes)
            ranked.each_with_index do |name, n|
              # Say which routine is being weighed, in the words an author would use. The
              # phase is quick now that nothing is priced, but it is the one place a build
              # names the routines it is deciding between, and that is worth seeing.
              @progress.of(n + 1, ranked.length, PlainWords.routine(name))
              next if chosen.include?(name) || forbidden.include?(name)

              size = sizes[name]
              next if size.nil? || !movable?(program, name)

              # TOO BIG TO FIT, and worth remembering rather than passing over in silence: this
              # is a routine the frame spends real time in that will run from the cartridge
              # instead, and the report has no other way to find out afterwards.
              if size > room
                @passed_over << PassedOver.new(name: name, bytes: size, room: room)
                next
              end

              chosen << name
              room -= size
            end
          end

          # The trees a name stands for: a routine the author wrote, the loop itself for the
          # game loop's body, or every announcement body for the routine those run in.
          def placeable_nodes(program, name)
            case name
            # The first loop only, matching the one #adopt_frame_body actually emits.
            when FRAME_ROUTINE then [program.walk.find { |node| node.kind == :loop }].compact
            when IRQ_ROUTINE   then irq_bodies(program)
            else program.walk.select { |node| node.kind == :func && node.name == name }
            end
          end

          # What a frame spends in each routine, dearest first. The cost model already
          # answers this. The game loop's body is in the list too, priced at the whole
          # frame, which is what puts it at the top where it belongs.
          #
          # Dearest FIRST rather than best value for its size, which is the other obvious
          # way to fill a fixed space. Value for size was tried and is worse here, because
          # the one routine that matters is usually also the biggest: it takes a handful
          # of small cheap routines first and then has no room left for the one the game
          # actually spends its time in. Measured on examples/breakout.rb, where value for
          # size moved the game-over screen and left the playing scene behind.
          #
          # FROM A MEASUREMENT WHERE THERE IS ONE, and from the shape of the program where
          # there is not. Nothing here estimates what a routine costs.
          #
          # A measured profile is the right answer and the only one that can be checked: the
          # game was run, and this is what its frames were really spent on. It survives a
          # rebuild because it is keyed by ROUTINE NAME rather than by anything that moves.
          #
          # With no profile there is no honest number to be had, so this does not invent one.
          # It orders by REACHABILITY instead — the frame's own body, then what the frame calls,
          # then what those call — which is a fact about the program rather than a guess about
          # the machine. It gets the common case right (a title screen's routines rank last,
          # because a frame never reaches them) and says nothing it cannot back.
          def ranked_by_frame_cost(program, sizes)
            @progress.step("choosing what goes in the quick memory")
            names = placeable_names(program, sizes)
            return @routine_profile.rank(names).select { |name| @routine_profile.worth_moving?(name) } if @routine_profile

            reachable_first(program, names)
          end

          # Everything that could be moved: the routines somebody wrote, plus the two nobody
          # did — the frame's own body and the routine the console interrupts into.
          def placeable_names(program, sizes)
            named = program.walk.select { |node| node.kind == :func }.map(&:name)
            named << FRAME_ROUTINE if sizes.key?(FRAME_ROUTINE)
            named << IRQ_ROUTINE if sizes.key?(IRQ_ROUTINE)
            named.select { |name| sizes[name].to_i.positive? }
          end

          # THE ORDER TO TRY WHEN NOTHING HAS BEEN MEASURED. The frame's own body first, since
          # it IS the frame; then out along the calls, nearest first, so a routine the frame
          # reaches every pass is preferred to one only a menu can get to.
          #
          # The routine the console interrupts into is placed by a fact about the program too,
          # not by a guess: a background that bends row by row is entered after every line the
          # display draws, 228 times a frame, and is then the busiest thing in the game by a
          # wide margin. Anything else enters it once a frame and it is worth almost nothing,
          # so it goes last.
          def reachable_first(program, names)
            candidates = names.to_set
            order = []
            order << FRAME_ROUTINE if candidates.include?(FRAME_ROUTINE) && frame_does_work?(program)
            order << IRQ_ROUTINE if candidates.include?(IRQ_ROUTINE) && interrupts_often?(program)

            order + calls_outward_from(program, frame_body(program), candidates - order.to_set)
          end

          # DOES THE CONSOLE INTERRUPT OFTEN ENOUGH FOR THAT ROUTINE TO BE WORTH THE ROOM? Both
          # answers are facts about the program rather than guesses about the machine, which is
          # what lets this be decided with nothing measured.
          #
          # A background bending row by row, with no copying engine left to feed it, is entered
          # after every line the display draws — 228 times a frame, which makes it the busiest
          # thing in the program. A timer is the other one: `per_second: 4000` lands 67 times a
          # frame. Anything else enters it once a frame and leaves again, and then the room is
          # better spent on almost anything else.
          def interrupts_often?(program)
            # ...and it is a bend the COPIER cannot feed that does it. Where an engine feeds
            # the rows the display announces nothing at all, and the block runs in the frame
            # with everything else. BendForm answers this for the report already, so the two
            # cannot disagree about it.
            return true if BendForm.kept_interrupt_reason(program)

            program.walk.any? { |node| node.kind == :timer_start && node.hz.to_i >= TICKS_A_FRAME }
          end

          # A timer at least this fast lands once a frame or more. Below it, the routine the
          # console interrupts into is entered for the frame's own sake and hardly ever else.
          TICKS_A_FRAME = 60

          # DOES THE FRAME'S OWN BODY DO ANYTHING? A game loop that only waits for the screen
          # is the case, and it is worth catching: every frame of it is the console asleep, so
          # moving the body buys nothing and costs the room and a longer call at every site.
          # It is the job WORTH_MOVING did for the estimate, asked of the program rather than
          # of a price.
          #
          # A BENDING BACKGROUND COUNTS EVEN THOUGH THE LOOP LOOKS EMPTY. Where the program
          # waits for frames, a bend's block is worked out IN the frame, into a table — so the
          # frame is doing 160 rows of the author's own arithmetic that the loop's statements
          # know nothing about. Miss that and the busiest thing in such a program is left in
          # the cartridge.
          NO_WORK_KINDS = %i[loop wait_vblank].freeze

          def frame_does_work?(program)
            body = frame_body(program) or return false
            return true unless BendForm.bends(program).empty?

            body.walk.any? { |node| !NO_WORK_KINDS.include?(node.kind) }
          end


          # Walk out along the calls from the code a frame runs, taking each routine WITH
          # everything it goes on to call before moving to the next.
          #
          # DEPTH FIRST, AND THAT IS THE WHOLE OF THIS RULE'S JUDGEMENT. Level by level looks
          # more sensible and is worse, because of scenes: a `case_var` puts every scene one
          # call from the frame, so all of them — the title, the game-over screen, the one
          # being played — rank ahead of anything a scene itself calls. The room then goes to
          # screens that are not on, and the routines doing the work are left in the cartridge.
          # Measured on examples/snake_buffered.rb, where level-by-level kept three scenes and
          # dropped `draw_all`, which is what that game spends its frame in.
          #
          # Taken depth first, a scene is followed immediately by what it uses, which matches
          # the one thing that is certainly true of a dispatch: only ONE of those scenes runs
          # on any frame.
          #
          # A routine a frame CANNOT reach is left off the list entirely rather than put at the
          # end of it. Moving one would cost nothing in speed — the room is empty otherwise —
          # but every call that then crosses between the two memories grows, so a title
          # screen's helpers would be paid for in cartridge size and never earn it back.
          def calls_outward_from(program, root, candidates)
            bodies = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            found = []
            visit = lambda do |node|
              called_by(node).each do |name|
                next if found.include?(name) || !candidates.include?(name)

                found << name
                body = bodies[name] and visit.call(body)
              end
            end
            visit.call(root) if root
            found
          end

          # The routines one body reaches: the ones it calls outright, and the scenes a
          # dispatch can land on. A scene IS a routine and a `case_var` IS how a game reaches
          # the one it is playing, so leaving those out would miss the most important routine
          # in most games — the playing scene.
          def called_by(node)
            node.walk.flat_map do |child|
              case child.kind
              when :call then [child.target]
              when :case then child.clauses.map(&:last)
              else []
              end
            end
          end

          def frame_body(program) = program.walk.find { |node| node.kind == :loop }

          # A routine the author asked to keep in the quick memory, that will not go
          # there, is a plain error where they wrote it — not a silent shrug.
          def guard_insisted_fits!(name, size, room)
            if size.nil?
              raise LoweringError,
                    "`func :#{name}, fast: true` asks to keep that routine in the console's quick " \
                    "memory, but nothing calls it, so it is never built. To fix this, call it or " \
                    "remove the routine."
            end
            return if size <= room

            raise LoweringError,
                  "`func :#{name}, fast: true` asks to keep that routine in the console's quick " \
                  "memory, but it needs #{size} bytes and only #{[room, 0].max} are free. To fix " \
                  "this, make the routine smaller, or use fewer variables and lists."
          end

          # A routine holding raw pre-assembled bytes stays where it is, whatever anyone
          # asked for. The framework cannot see inside those bytes, and code that is moved
          # has to be built entirely from instructions that do not care where they run —
          # which is a promise it can make about its own output and not about someone
          # else's.
          def movable?(program, name)
            placeable_nodes(program, name).none? { |node| node.walk.any? { |c| c.kind == :raw } }
          end
        end
      end
    end
  end
end

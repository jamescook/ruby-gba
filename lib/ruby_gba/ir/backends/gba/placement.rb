# frozen_string_literal: true

require_relative "../../../console/hardware" # the register addresses this reads, a leaf both sides sit on

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
        # between the two has to get the address into a register and jump through it —
        # six instructions instead of one from the cartridge, where the address is built,
        # and three and a word of data from the quick memory, where a routine reads its big
        # numbers from a table at its own end (see {NumberTable}). A call that stays on one
        # side is untouched,
        # and since the moved routines are copied as ONE block their distances from each
        # other are preserved, so they call each other exactly as they did before.
        module Placement
          include Console::Hardware

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
          # least afford it. Measured on the Wolfenstein port, whose game loop wanted 21.6K of a
          # 21.6K space and was offered 20.6K: it missed by the width of the margin, and
          # the whole frame ran from the cartridge at about a third of the speed.
          #
          # If the bound is ever wrong again the build stops with the message in
          # #check_fast_code_fits!, which names the overrun and what to do about it. A loud
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
          # in #check_fast_code_fits!, on a game that fits: the chooser adds up sizes that
          # are each a little under, takes one routine more than there is room for, and
          # the build stops with advice about a routine the author would have to guess at.
          # Twelve was under by eight a call, which was worth 224 bytes on one routine of
          # the Wolfenstein port alone.
          CROSS_CALL_GROWTH = 20

          # ...and the most one can add in a routine that keeps a number table and can reach
          # it: the address is one read and one word of the table, then the same move and
          # jump. Four each, less the four-byte branch it replaces.
          CROSS_CALL_GROWTH_WITH_TABLE = 12

          # Saving the return address on the way in and returning at the end. The game
          # loop's body measures without these, because inline it needs neither — and it is
          # the only routine that does. Every other one, the routine the console interrupts
          # into among them, is measured as the routine it already is with both instructions
          # counted, so charging them again was eight bytes of room lost for each one kept.
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

            probe = measure_routines(program)
            chosen = choose_from_measurement(program, probe, insisted)
            nearer = variables_kept_routines_want_nearer(probe, chosen)
            unless nearer.empty?
              # MEASURED AGAIN, with those variables where they are going to be. Moving a
              # variable changes the size of every routine that names it, and the choice
              # just made was made from the sizes of the other layout. A second measurement
              # is the only charge that is of the program really built; a game pays for it
              # only when it has more variables than the base register reaches AND keeps a
              # routine that uses one past the line.
              probe = measure_routines(program, variables_first: nearer)
              chosen = choose_from_measurement(program, probe, insisted)
            end
            allocate_variables_where_measured(probe)
            chosen
          end

          # Lower the program once with nothing moved, to learn how big each routine comes out
          # and how much memory is left. +variables_first+ are given their addresses before
          # anything else names a variable.
          def measure_routines(program, variables_first: [])
            # The probe reports through the same object this one does, so the measuring pass
            # shows its own progress rather than going quiet for as long as a lowering takes.
            @progress.step("measuring the routines")
            probe = self.class.new(fast_cartridge: @fast_cartridge, progress: @progress)
            probe.lower(program, fast_funcs: Set.new, variables_first: variables_first)
            probe
          end

          # THE VARIABLES THE KEPT ROUTINES USE, when any of them sits where the base register
          # cannot reach — every one of them, nearest first in the order they were named,
          # ready to be claimed before the rest. Empty when nothing needs to move, which is
          # every game with fewer variables than the register reaches.
          #
          # A variable within reach is read in one instruction; one past it needs its whole
          # address first. Left to the order a program names them in, the ones past the line
          # are whichever came last, and nothing steered them away from the code that can
          # least afford them. The routines left in the cartridge take the far places
          # instead, where a longer read costs cartridge bytes, of which there are millions.
          def variables_kept_routines_want_nearer(probe, chosen)
            places = probe.var_addresses
            far = places.select { |_, address| address - IWRAM_START > Primitives::FURTHEST_FROM_BASE }
            return [] if far.empty?

            used = chosen.flat_map { |name| probe.variables_named_by(name) }.uniq
            used.any? { |name| far.key?(name) } ? used : []
          end

          # The variables the routine +name+ names, read off this pass.
          def variables_named_by(name)
            span = @functions.func_ranges[name]
            span ? @primitives.variables_named_in(span) : []
          end

          # Pick the routines to keep from what +probe+ measured. Leaves the sizes, the charges
          # and the routines turned away where the rest of the build and the report read them.
          def choose_from_measurement(program, probe, insisted)
            # The routines the build makes for its scenes (their moving sprites, a see-through
            # layer's amounts) are nowhere in the program, so the probe is the one that knows
            # them.
            @scene_routines = probe.routines_for_scenes
            @routines_placed_with_frame = probe.map_view_routines
            @crossing_targets = crossing_call_targets(program, probe.generated_calls_by_routine)
            crossings = @crossing_targets.transform_values(&:size).tap { |counts| counts.default = 0 }
            loads = probe.number_loads_by_routine
            # What each routine could come to with every number built, and what a table then
            # does to it.
            built = moved_sizes(probe.func_sizes, crossings)
            effects = table_effects(built, loads, crossings)
            sizes = built.to_h { |name, size| [name, size - effects.fetch(name).saved] }
            # Kept, because the emitter needs the line each routine's reads were drawn at.
            @table_effects = effects
            @call_charges = effects.transform_values(&:call_charge)
            # Every allocation is rounded up to a whole word, so the gap the probe leaves is
            # the gap there really is — there is no alignment slop to keep back for.
            room = probe.iwram_free
            @passed_over = []

            chosen = Set.new
            room = place_insisted(program, insisted, sizes, room, chosen)
            place_by_frame_cost(program, sizes, room, chosen) if @fast_code
            # Kept for the report: what each routine came to, and what a reader will want to
            # know afterwards is why theirs is not on the list. A routine that was kept is
            # down as what it was charged in the end, its calls to its neighbours given back.
            @routine_sizes = sizes.merge(chosen.to_h { |name| [name, sizes[name] - bytes_given_back(name, chosen)] })
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

          # The calls to a routine the build made for itself that each routine holds, read off
          # the throwaway pass by where each call was written (see #crossing_call_targets):
          # the name of the routine called, or nil for one that always stays in the cartridge.
          def generated_calls_by_routine
            @functions.func_ranges.transform_values do |range|
              generated_call_sites.select { |pos, _| range.cover?(pos) }.map(&:last)
            end.reject { |_, targets| targets.empty? }
          end

          # Each such call as [where it was written, the routine it calls or nil].
          def generated_call_sites = (@generated_call_sites ||= [])

          # The loads a number table could take in each routine, top to bottom, each placed by
          # how far into its routine it is. Likewise read off the throwaway pass.
          def number_loads_by_routine
            loads = @emit.number_loads
            @functions.func_ranges.transform_values do |range|
              loads.select { |load| range.cover?(load.pos) }.map { |load| load.with(pos: load.pos - range.begin) }
            end
          end

          # What the routine +name+'s number table goes by — the size the routine was measured
          # at and how far from that end a load is still read (a {TableEffect}; see
          # {NumberTable}). Nil for a routine that gets no table: one that is not being
          # emitted into the quick memory, or one the build never measured.
          def number_table_for(name)
            return nil unless @emitting_hot

            (@table_effects || {})[name]
          end

          # Once the game loop's body is going to the quick memory it needs a name and a
          # place in the routine table, so that everything downstream — emitting it,
          # calling it, reporting it — treats it as the routine it has become. Its "body"
          # is the loop node's own statements.
          def register_frame_routine(program)
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
            check_fast_code_fits!
          end

          # What each moved routine was CHARGED against what it came out at, for the one
          # test that can tell whether the charge (#moved_sizes, less what #table_effects
          # takes off) is still the upper bound it claims to be (a charge that is short does not fail here — it fails much later, in
          # #check_fast_code_fits!, on a game that fits). Valid after #lower.
          def charged_and_emitted_sizes
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
            # None of the three is known yet, so each is a slot filled in once it is: the
            # block where it sits in the cartridge, where it is going, and how much of it
            # there is — a size rather than an address, so that one refers to nothing.
            @primitives.emit_start_copy_engine(
              from: -> { emit_load_label_address(ACC, HOT_START) },
              to: -> { emit_load_fast_address(ACC, HOT_START) },
              control: lambda do
                @emit.fixups << Emit::AddressLoad.new(pos: pos, kind: :hot_size, reg: ACC, target: nil)
                emit(ASM.load_immediate_fixed(ACC, 0))
              end
            )
          end

          # Patch in the transfer's size and start it: whole words, both ends advancing.
          # A custom fixup kind #resolve_fixups doesn't know about — Emit hands it here
          # via the resolver map GBA#lower builds (see GBA#lower).
          def resolve_hot_size(fix)
            words = @hot_bytes / 4
            @emit.patch16(fix.pos, ASM.load_immediate_fixed(fix.reg, words | DMA_32BIT | DMA_ENABLE))
          end

          # Call a routine. A call that stays on one side of the cartridge/quick-memory
          # line is the plain jump it always was; one that crosses has to get the address
          # into a register and jump through it, because the two are far too far apart for a
          # jump to reach. From the cartridge the address is built; from a routine in the
          # quick memory it is read from that routine's number table where the read reaches.
          def emit_call_func(name)
            generated_call_sites << [@emit.pos, name] if @functions.generated_func?(name)
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
          # cartridge, whichever call reaches it: the digit routines (see
          # Drawing#emit_digit_routines), a flash chip's byte routines (see SaveChip) and the
          # routine that brings a background another set of tiles (see
          # BackgroundDrawing#emit_set_swap_routines).
          # Plain when the call is cold too, and the same address-and-jump-through
          # #emit_call_func's own crossing call uses when the call is running from inside
          # the moved block, since a label back in the cartridge is too far from the quick
          # memory for a relative branch to reach. So it is counted where the measuring
          # pass writes it, as a call the build made for itself (see #crossing_call_targets).
          def emit_call_cold_routine(label)
            generated_call_sites << [@emit.pos, nil] # nil: no routine that could be kept beside the caller
            return emit_branch(:bl, label) unless @emitting_hot

            emit_load_label_address(ADDR, label)
            emit_call_through(ADDR)
          end

          # Load the quick-memory address of a label inside the moved block. Where the
          # block lands is not known until every variable has one, so this is a
          # fixed-size placeholder patched in the second pass — the same trick a
          # reference to embedded data uses.
          def emit_load_fast_address(reg, label)
            @emit.fixups << Emit::AddressLoad.new(pos: pos, kind: :fast_addr, reg: reg, target: label)
            emit(ASM.load_immediate_fixed(reg, 0))
          end

          # Also a custom fixup kind, handed to Emit's resolver map the same way
          # #resolve_hot_size is.
          def resolve_fast_address(fix)
            offset = @emit.labels.fetch(fix.target) - @emit.labels.fetch(HOT_START)
            @emit.patch16(fix.pos, ASM.load_immediate_fixed(fix.reg, @hot_base + offset))
          end

          # A TABLE OF WHERE ROUTINES START, one word each in the order given, for a call that
          # picks one by number (see Functions#emit_call_one_of). It is kept in the cartridge
          # with the pictures and the tunes rather than in the code, because a routine moved to
          # the quick memory takes its code with it — and a table of a hundred and more words
          # would take that much of the 32K along for one load a call.
          #
          # EACH WORD IS WHERE ITS ROUTINE RUNS: the quick memory for a routine moved there, the
          # cartridge for one left behind. Neither is known until every routine has its place, so
          # the words are filled in with the other placeholders, in the second pass. A call
          # through the table jumps through a register either way, so it is the same few
          # instructions wherever the routines landed, and it never grows when one of them moves.
          #
          # Two calls picking from the same list share one table.
          def routine_table(names)
            @routine_tables ||= {}
            @routine_tables[names] ||= begin
              blob = :"__routines#{@routine_tables.size}"
              @emit.data_blobs[blob] = "\x00".b * (4 * names.length)
              names.each_with_index do |name, i|
                @emit.fixups << Emit::BlobWord.new(kind: :routine_word, blob: blob, offset: 4 * i,
                                                   target: @functions.func_label(name))
              end
              blob
            end
          end

          # Also a custom fixup kind, handed to Emit's resolver map the same way.
          def resolve_routine_word(fix)
            @emit.patch_word(fix.blob, fix.offset, runtime_address(fix.target))
          end

          # Where code label +label+ is when the program runs: inside the moved block it is
          # wherever boot copied the block to, and anywhere else it is where it sits in the
          # cartridge.
          def runtime_address(label)
            at = @emit.labels.fetch(label)
            start = @emit.labels[HOT_START]
            return @emit.label_address(label) unless start && at >= start && at < @emit.labels.fetch(HOT_END)

            @hot_base + (at - start)
          end

          private

          # The quick memory is 32KB and everything shares it. Growing past what is left
          # would quietly overwrite the console's own startup stack, so say so instead,
          # and say what to do about it.
          def check_fast_code_fits!
            over = @memory.overrun
            return if over.zero?

            raise LoweringError,
                  "this program needs #{@memory.used} bytes of the console's quick memory, " \
                  "which is #{over} more than there is. #{@hot_bytes} of it is routines kept there to " \
                  "run faster. To fix this, mark a routine `func :name, fast: false` to leave it in the " \
                  "cartridge, or build with `fast_code: false` to keep them all there."
          end

          # EVERY VARIABLE GOES WHERE THE MEASURING PASS PUT IT, before this pass mentions one.
          #
          # A variable is given its address the first time anything names it, and the two
          # passes do not name them in the same order: the measuring pass emits every routine
          # where it was written, and this one emits the routines it keeps in the quick memory
          # after all the others. So a variable the build made for itself inside a routine —
          # a loop's counter, a walk's place — landed somewhere else the second time. And where
          # a variable lands decides what reaching it costs: one within reach of the base
          # register is a single instruction, one past it needs its whole address, and an
          # address is one, two or three instructions depending on its bits.
          #
          # That made the measurement a measurement of a slightly different program. In a game
          # with over a thousand variables, routines came out holding address loads the
          # measuring pass never saw, which is growth nobody charged for; and two loads the
          # measuring pass saw as one number, sharing a word of a table, need not have been.
          # Claiming them all here, in the order that pass did, makes them the same numbers.
          def allocate_variables_where_measured(probe)
            probe.var_addresses.each_key { |name| var_addr(name) }
          end

          # The routines the author named one way or the other. `fast: true` is taken as
          # an instruction and is placed before anything the framework picked; `fast:
          # false` is taken as an instruction too and is never picked.
          def funcs_marked(program, want)
            program.walk.select { |node| node.kind == :func && node.fast == want }
                   .map { |node| node.name }.to_set
          end

          # How big each routine will be once moved. A routine measured in the throwaway
          # pass GROWS in only one way — every call it makes to a routine left behind grows
          # by CROSS_CALL_GROWTH — so charging it for ALL of its calls is an upper bound
          # (#moved_sizes). It also shrinks in one way, by reading its big numbers from a
          # table, and what is certain of that comes off again (#table_effects). Being a
          # little pessimistic here means the last routine chosen might have fitted after
          # all; being optimistic would mean a build that overruns the memory, so this is
          # the direction to be wrong in.
          #
          # NOT EVERY CROSSING CALL IS A `call` THE AUTHOR WROTE, and each kind that was
          # missed made this an under-estimate rather than an upper bound. Some are invented
          # by the lowering, with no `call` node anywhere to show for them. One is counted
          # from the tree here, and the rest where the measuring pass wrote them (see
          # #crossing_call_targets):
          #
          # A MULTI-WAY DISPATCH calls the scene it lands on, one call per clause, built out
          # of `call` nodes made while emitting rather than nodes the tree holds (see
          # Functions#emit_case). That is a game's whole scene table — and it lands on the
          # game loop's own body, which is the routine that can least afford to be
          # mismeasured, because it is the first one the chooser takes.
          #
          # A CALL PICKED BY NUMBER is not among them, because it never grows: it jumps
          # through an address read out of a table, whichever memory the routine it lands in
          # was given (see #routine_table).
          #
          # Answers the routine each such call in +node+ names, one entry a call, because
          # which routine it is decides whether the call crosses in the end (see
          # #bytes_given_back).
          def crossing_targets_in(node)
            node.walk.flat_map do |child|
              case child.kind
              when :call then [child.target]
              when :case then child.clauses.map(&:last)
              else []
              end
            end
          end

          # THE CALLS COUNTED WHERE THEY ARE WRITTEN, because no node of the tree says where:
          #
          # Calls to routines the build made for itself — each scene's moving sprites, the
          # sprites nothing moves, a see-through layer's amounts, a big map's view brought
          # along. Most are made by the frame, in the gap after the picture, but a see-through
          # layer's amounts are told again wherever something puts the blend back (a scene
          # taking over the display, a fade lifting), and a big map's view is filled again
          # wherever its background goes up or an area's tiles come in.
          #
          # Calls to routines that always stay in the cartridge (#emit_call_cold_routine). A
          # run-time digit shares one glyph-drawing routine per font, so a game with a score on
          # screen calls it once per digit place — a couple of hundred bytes in
          # examples/breakout.rb. A 128K flash chip is read and written a byte at a time through
          # one, so a save routine holds a call for every byte it reads or writes. A background
          # that walks between areas calls one wherever it is shown a map, to bring an area's
          # tiles in.
          #
          # +made_calls+ is both kinds, by routine, the interrupt's included: for each call the
          # routine it names, or nil for one that always stays in the cartridge.
          #
          # Answers, for each routine, the routine named by every call in it that COULD cross.
          def crossing_call_targets(program, made_calls = {})
            calls = Hash.new { |_, _| [] }
            program.walk.each do |node|
              name = node.kind == :loop ? FRAME_ROUTINE : (node.name if node.kind == :func)
              calls[name] = crossing_targets_in(node) if name
            end
            calls[IRQ_ROUTINE] = irq_bodies(program).flat_map { |node| crossing_targets_in(node) }
            made_calls.each { |name, targets| calls[name] += targets }
            calls
          end

          # A CALL BETWEEN TWO KEPT ROUTINES NEVER GREW, so what +name+ was charged for it
          # comes back once both are in +chosen+. Every call is charged as though it crossed,
          # because the charging starts before anything is chosen; but the kept routines are
          # copied as one block and go on calling each other with the plain jump they were
          # measured with. Keeping MORE routines can only turn more calls plain, never fewer,
          # so nothing given back ever has to be taken away again.
          def bytes_given_back(name, chosen)
            @call_charges.fetch(name, 0) * @crossing_targets[name].count { |target| chosen.include?(target) }
          end

          # WHAT KEEPING +name+ ADDS to the room taken, with +chosen+ kept already: its own
          # charge less its calls to them and to itself, less what each of THEM gets back for
          # calling it. That is less than its size whenever it has neighbours — which is how
          # a routine that looked too big for the room comes to fit.
          def bytes_added_by(name, chosen, sizes)
            beside = chosen | [name]
            from_the_rest = chosen.sum do |other|
              other == name ? 0 : @call_charges.fetch(other, 0) * @crossing_targets[other].count(name)
            end
            sizes[name] - bytes_given_back(name, beside) - from_the_rest
          end

          # +measured+ is each routine's size off the throwaway pass, and +crossings+ how many
          # calls each holds that could cross.
          def moved_sizes(measured, crossings)
            measured.to_h do |name, size|
              wrapper = name == FRAME_ROUTINE ? ROUTINE_WRAPPER : 0
              [name, size + (crossings[name] * CROSS_CALL_GROWTH) + wrapper]
            end
          end

          # HOW BIG EACH ROUTINE WILL BE ONCE ITS BIG NUMBERS ARE READ FROM A TABLE, which is
          # how a routine kept in the quick memory is emitted (see {NumberTable}). The throwaway
          # pass built every number, so what it measured is too big by exactly what the table
          # saves — and a routine charged too much is a routine, or the one after it, turned
          # away from room it would have fitted in.
          #
          # THE CHARGE STILL HAS TO BE AN UPPER BOUND, so the saving taken has to be one the
          # real pass makes. Which loads become reads is settled here, from the measurement
          # (see #loads_read_from_table), and the emitter is handed the line that was drawn,
          # so it reads those same loads. Each saves every instruction it was built from but
          # the one that reads. The table then costs a word for each DIFFERENT number among
          # them, since two loads of one number read the same word — which is most of what a
          # routine that names one register or one list over and over gets back. (Two loads
          # are one number in the real pass because they were one in the measuring pass: see
          # #allocate_variables_where_measured.)
          #
          # The routine the console interrupts into is written out by hand and gets no table.
          def table_effects(built, loads, crossings)
            built.to_h do |name, size|
              if name == IRQ_ROUTINE
                next [name, TableEffect.new(measured_bytes: size, read_within: 0, saved: 0, call_charge: CROSS_CALL_GROWTH)]
              end

              [name, table_effect(size, loads[name] || [], crossings[name])]
            end
          end

          # WHAT A NUMBER TABLE DOES TO ONE ROUTINE, settled before the routine is emitted
          # for real:
          #
          #   +measured_bytes+  its size with every number built, calls that could cross and
          #                     all — the routine the distances below are counted in
          #   +read_within+     how far from the end of THAT routine a load can be and still
          #                     be read from the table rather than built
          #   +saved+           the bytes that come off what it is charged
          #   +call_charge+     what it is still charged for one call that could cross, and
          #                     so what it is given back for one that does not
          #                     (see #bytes_given_back)
          TableEffect = Data.define(:measured_bytes, :read_within, :saved, :call_charge)

          # +size+ is the routine with every number built, +loads+ the loads a table could
          # take, and +crossings+ how many calls it holds that could cross.
          #
          # A CROSSING CALL IS A LOAD TOO: the address it jumps through is read from the table
          # like any other (see #emit_call_func), so it grows a call by
          # CROSS_CALL_GROWTH_WITH_TABLE rather than by CROSS_CALL_GROWTH. Nothing says where
          # in the routine such a call is — it is counted off the tree, not off the code — so
          # that is taken only for a routine small enough that a read anywhere in it reaches a
          # table of every word it could hold.
          def table_effect(size, loads, crossings)
            read = loads_read_from_table(size, loads, crossings)
            gone = read.sum { |load| (load.instructions - 1) * 4 }
            saved = gone - (4 * read.map(&:word).uniq.size)
            whole_routine_reaches = read.size == loads.size && size - gone + (4 * crossings) <= NumberTable::REACH
            unless whole_routine_reaches
              # THE LINE, counted from the measured end: as far as a read reaches, plus what
              # the reads below the line save (anything above it has all of them between it
              # and the table), less room for the crossing calls' words. It falls between the
              # topmost load that is read and the one above it — and a crossing call's own
              # address load is read or built by the same line, wherever the call is.
              within = (NumberTable::REACH - (4 * crossings) + gone).clamp(0, size)
              return TableEffect.new(measured_bytes: size, read_within: within, saved: saved,
                                     call_charge: CROSS_CALL_GROWTH)
            end

            TableEffect.new(measured_bytes: size, read_within: size, call_charge: CROSS_CALL_GROWTH_WITH_TABLE,
                            saved: saved + (crossings * (CROSS_CALL_GROWTH - CROSS_CALL_GROWTH_WITH_TABLE)))
          end

          # THE LOADS THAT WILL BE READS, worked out from the bottom of the routine up, because
          # A ROUTINE SHRINKS AS ITS NUMBERS BECOME READS. The last load is nearest the table
          # and reaches if anything does. Each load above it is further from the end by the
          # code in between, but nearer by what the reads below it saved — so each is asked
          # with those taken off, and the first one that still cannot reach ends it, since
          # everything above that one is further again. The reads are always the bottom of
          # the routine.
          #
          # A WORD IS AS FAR INTO THE TABLE AS THE READS ABOVE IT PUT IT, and that settles
          # itself for the loads counted here: each read above another is at least one
          # instruction of code between it and the end, and at most one word in the table
          # ahead of the other's, so the topmost read is the one that reaches least. What it
          # cannot see is a call that crosses. Such a call reads its address from the table
          # too, nothing says where in the routine it is, and one sitting just above the line
          # can put its word in first — so the topmost read is asked as though every one of
          # the +crossings+ had.
          #
          # The emitter draws the same line, by how far a load is from the measured end (see
          # NumberTable#reaches?), so these are the loads it reads.
          def loads_read_from_table(size, loads, crossings)
            gone_below = 0
            loads.reverse.take_while do |load|
              reaches = (size - load.pos) - gone_below + (4 * crossings) <= NumberTable::REACH
              gone_below += (load.instructions - 1) * 4 if reaches
              reaches
            end
          end

          # The trees the console runs on an announcement: every bending background's block
          # and every timer's tick body. There is no one node standing for all of it the way
          # a routine has one, so the pieces are gathered.
          #
          # A bend in a paced program is not among them: its block runs in the frame like
          # ordinary code, into a table, and what the announcement then does is read one
          # number out of it (see {BendForm}).
          def irq_bodies(program)
            kinds = BendForm.rows_per_scanline?(program) ? %i[scroll_rows on_timer] : %i[on_timer]
            program.walk.select { |node| kinds.include?(node.kind) }
          end

          # The routines the author asked for by name, placed before anything the
          # framework picked and not held to its share of the room. Answers what is left.
          #
          # A scene insisted on takes the routines the build made for it (its sprites, its
          # see-through amounts) with it.
          def place_insisted(program, insisted, sizes, room, chosen)
            movable = program.walk.select { |node| node.kind == :func && insisted.include?(node.name) }.map(&:name)
            movable += scene_routines.filter_map { |routine, scene| routine if insisted.include?(scene) && sizes[routine] }
            movable.each do |name|
              adds = sizes[name] && bytes_added_by(name, chosen, sizes)
              guard_insisted_fits!(name, adds, room)
              chosen << name
              room -= adds
            end
            room
          end

          # Then whatever a frame spends the most time in, biggest earner first, within
          # the framework's own share. Anything that will not fit is skipped rather than
          # stopping the fill — a small routine after a large one still gets its chance.
          #
          # AND THE LIST IS GONE THROUGH AGAIN WHILE ANYTHING WAS ADDED, because what a routine
          # takes depends on what is kept beside it (see #bytes_added_by): one turned away
          # near the top can fit once a routine it calls, or that calls it, has gone in below.
          def place_by_frame_cost(program, sizes, room, chosen)
            forbidden = funcs_marked(program, false)
            # A scene the author kept out of the quick memory keeps what the build made for it
            # out with it: its sprites, and its see-through amounts.
            forbidden += scene_routines.filter_map { |routine, scene| routine if forbidden.include?(scene) }
            ranked = ranked_by_frame_cost(program, sizes)
            wanted = ranked.reject { |name| forbidden.include?(name) || sizes[name].nil? || !movable?(program, name) }
            first_time = true
            loop do
              kept_before = chosen.size
              room = place_what_fits(wanted, sizes, room, chosen, named: (ranked if first_time))
              first_time = false
              break if chosen.size == kept_before
            end
          end

          # Go down +wanted+ once, keeping each routine that fits in +room+, and answer the
          # room left. Leaves @passed_over as the routines THIS pass turned away, so after the
          # last pass it is the routines that never fitted.
          def place_what_fits(wanted, sizes, room, chosen, named: nil)
            @passed_over = []
            wanted.each do |name|
              # Say which routine is being weighed, in the words an author would use. The
              # phase is quick now that nothing is priced, but it is the one place a build
              # names the routines it is deciding between, and that is worth seeing.
              @progress.report_count(named.index(name) + 1, named.length, Messages::PlainWords.routine(name)) if named
              next if chosen.include?(name)

              adds = bytes_added_by(name, chosen, sizes)
              # TOO BIG TO FIT, and worth remembering rather than passing over in silence: this
              # is a routine the frame spends real time in that will run from the cartridge
              # instead, and the report has no other way to find out afterwards.
              if adds > room
                @passed_over << PassedOver.new(name: name, bytes: adds, room: room)
                next
              end

              chosen << name
              room -= adds
            end
            room
          end

          # The trees a name stands for: a routine the author wrote, the loop itself for the
          # game loop's body, or every announcement body for the routine those run in.
          def placeable_nodes(program, name)
            case name
            # The first loop only, matching the one #register_frame_routine actually emits.
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
            ranked = if @routine_profile
                       @routine_profile.order_by_work(names).select { |name| @routine_profile.worth_quick_memory?(name) }
                     else
                       reachable_first(program, names)
                     end
            beside_frame_routine(ranked, sizes)
          end

          # Everything that could be moved: the routines somebody wrote, plus the two nobody
          # did — the frame's own body and the routine the console interrupts into.
          def placeable_names(program, sizes)
            named = program.walk.select { |node| node.kind == :func }.map(&:name)
            named << FRAME_ROUTINE if sizes.key?(FRAME_ROUTINE)
            named << IRQ_ROUTINE if sizes.key?(IRQ_ROUTINE)
            named.concat(scene_routines.keys)
            named.select { |name| sizes[name].to_i.positive? }
          end

          # The routines the build made for a scene — its sprite writer, a see-through layer's
          # amounts — by name, with the scene each works for (the frame's own routine for a
          # see-through layer no one scene owns). Empty until the measuring pass has run.
          def scene_routines = @scene_routines || {}

          # The routines that are the frame's own work, written once and called: the one that
          # brings each big map's view along (see GBA#prepare_map_view_routines). Empty until
          # the measuring pass has run.
          def routines_placed_with_frame = @routines_placed_with_frame || []

          # THE FRAME'S OWN ROUTINES GO RIGHT AFTER THE FRAME'S, whatever they measured.
          #
          # Bringing a big map's view along was written out in the frame's routine, so it was
          # kept in the quick memory whenever the frame was. As a routine of its own it would
          # be weighed by what a frame was measured to spend in it, and that measure is taken
          # with nobody playing: the view stands still, and the routine does a few dozen
          # instructions finding that out. Its real work is on the frames the view moves, and
          # most of all on the frame a whole view is filled, which shows the backdrop over
          # its top rows when the fill runs at the cartridge's speed. So it keeps the place
          # the frame has, as it had when it was part of the frame.
          def beside_frame_routine(ranked, sizes)
            own = routines_placed_with_frame.select { |name| sizes[name].to_i.positive? }
            return ranked if own.empty? || !ranked.include?(FRAME_ROUTINE)

            rest = ranked - own
            rest.insert(rest.index(FRAME_ROUTINE) + 1, *own)
          end

          # WHAT THE BUILD MADE FOR A SCENE GOES RIGHT AFTER THE SCENE, when nothing has been
          # measured. The frame calls such a routine on the frames the scene runs, so it is
          # worth what the scene is worth, and nothing in the tree reaches it for the walk below
          # to find.
          def with_scene_routines(order, candidates)
            of_scene = scene_routines.select { |routine, _| candidates.include?(routine) }
                                      .group_by { |_, scene| scene }
            order.flat_map { |name| [name, *of_scene.fetch(name, []).map(&:first)] }
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

            reached = calls_outward_from(program, frame_body(program), candidates - order.to_set)
            with_scene_routines(order + reached, candidates)
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
            return true unless BendForm.scroll_rows_nodes(program).empty?

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
              callees_of(node).each do |name|
                next if found.include?(name) || !candidates.include?(name)

                found << name
                body = bodies[name] and visit.call(body)
              end
            end
            visit.call(root) if root
            found
          end

          # The routines one body reaches: the ones it calls outright, the scenes a dispatch
          # can land on, and every routine a call picked by number can. A scene IS a routine
          # and a `case_var` IS how a game reaches the one it is playing, so leaving those out
          # would miss the most important routine in most games — the playing scene.
          def callees_of(node)
            node.walk.flat_map(&:callees)
          end

          def frame_body(program) = program.walk.find { |node| node.kind == :loop }

          # A routine the author asked to keep in the quick memory, that will not go
          # there, is a plain error where they wrote it — not a silent shrug.
          def guard_insisted_fits!(name, size, room)
            if size.nil?
              raise LoweringError,
                    "#{fast_true_snippet(name)} asks to keep that routine in the console's quick " \
                    "memory, but nothing calls it, so it never runs. To fix this, call it or " \
                    "remove the routine."
            end
            return if size <= room

            raise LoweringError,
                  "#{fast_true_snippet(name)} asks to keep that routine in the console's quick " \
                  "memory, but it needs #{size} bytes and only #{[room, 0].max} are free. To fix " \
                  "this, make the routine smaller, or use fewer variables and lists."
          end

          # What the author wrote to insist on +name+: a scene's own word for the scene and for
          # the routines the build made for it, a func's for anything else.
          def fast_true_snippet(name)
            scene = scene_routines.fetch(name, name).to_s
            return "`func :#{name}, fast: true`" unless scene.start_with?("_scene_")

            "`scene :#{scene.delete_prefix('_scene_')}, fast: true`"
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

# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Which routines run from the console's quick memory, and how they get there.
        #
        # THE HARDWARE, briefly. Code lives in the cartridge, which the console reads
        # over a narrow, slow connection. It also has 32KB of memory of its own that runs
        # at full speed with nothing to wait for. Nothing decides which one a routine runs
        # from except where its bytes happen to be — so a routine can be made faster by
        # copying it into the quick memory at boot and jumping there instead. Measured on
        # a real inner loop, that is worth about two and a half times.
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
          # row by row is entered after every single line the display draws, 228 times a
          # frame, and then it is the busiest routine in the program by a wide margin.
          # Measured on examples/lake.rb: 47.6 scanlines a frame down to 24.2.
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

          # A little of the spare quick memory the framework leaves alone when it is
          # choosing on its own, so a program never sits at exactly zero free.
          #
          # It does not need to be more than this. The choosing is done afresh on every
          # build, from where the variables actually reached that time, so a program that
          # grows simply gets a smaller share next build — it can never find that a past
          # build spent the room it now needs. What is left here is only so that the
          # report has a number in it and a routine asked for by name has somewhere to go.
          AUTO_RESERVE = 1024

          # A call from a moved routine to one still in the cartridge grows from one
          # instruction to four, so a routine can come out bigger than it measured. This
          # is the most any one call can add.
          CROSS_CALL_GROWTH = 12

          # The moved block starts on a whole word, so it can begin up to three bytes
          # later than the last variable ended.
          ALIGNMENT_ALLOWANCE = 4

          # Saving the return address on the way in and returning at the end. The game
          # loop's body measures without these, because inline it needs neither.
          ROUTINE_WRAPPER = 8

          # Names of the routines that will run from the quick memory. Valid after #lower.
          def fast_funcs = @fast_funcs.dup

          # Where the moved block ended up and how big it is, for the report. nil when
          # nothing moved.
          attr_reader :hot_base, :hot_bytes

          # How much of the quick memory this build used, and what is left — the numbers
          # `rom.explain` prints. Valid after #lower.
          def iwram_report
            used = @next_var - IWRAM_START
            {
              funcs: @fast_funcs.to_a,
              code_bytes: @hot_bytes.to_i,
              used_bytes: used,
              free_bytes: [HOT_CEILING - @next_var, 0].max,
              total_bytes: IWRAM_SIZE,
            }
          end

          # Decide what moves. Runs before anything is emitted, and answers a set of func
          # names — empty when there is nothing worth moving or the author turned it off.
          def choose_fast_funcs(program)
            insisted = funcs_marked(program, true)
            return insisted if insisted.empty? && !@fast_code

            probe = self.class.new(fast_cartridge: @fast_cartridge)
            probe.lower(program, fast_funcs: Set.new) # measure the program with nothing moved
            sizes = moved_sizes(program, probe.func_sizes)
            room = HOT_CEILING - probe.iwram_high_water - ALIGNMENT_ALLOWANCE

            chosen = Set.new
            room = place_insisted(program, insisted, sizes, room, chosen)
            place_by_frame_cost(program, sizes, room - AUTO_RESERVE, chosen) if @fast_code
            chosen
          end

          # The memory address a func runs from once the program is lowered — its place in
          # the moved block, or nil if it stayed in the cartridge. Used to resolve a call
          # that crosses between the two.
          def fast_func_address(name)
            return nil unless @fast_funcs.include?(name)

            @hot_base + (@labels.fetch(func_label(name)) - @labels.fetch(HOT_START))
          end

          # How far the variables (and lists, and the mixer's memory) reached. Read off
          # the throwaway pass to know how much room is left for code.
          def iwram_high_water = @next_var

          # Each func's size in bytes, likewise read off the throwaway pass.
          def func_sizes
            @func_ranges.transform_values(&:size)
          end

          # Once the game loop's body is going to the quick memory it needs a name and a
          # place in the routine table, so that everything downstream — emitting it,
          # calling it, reporting it — treats it as the routine it has become. Its "body"
          # is the loop node's own statements.
          def adopt_frame_body(program)
            return unless @fast_funcs.include?(FRAME_ROUTINE)

            loop_node = program.walk.find { |node| node.kind == :loop }
            @funcs[FRAME_ROUTINE] = loop_node if loop_node
          end

          # Emit the moved routines, back to back, between the two labels boot copies
          # between. One block, not several, so their distances from each other survive
          # the copy and they go on calling each other with a plain jump.
          def emit_hot_functions
            return if @fast_funcs.empty?

            emit(ASM.loop_forever) # fall-through guard, outside the block so it is not copied
            place_label(HOT_START)
            @emitting_hot = true
            @funcs.each { |name, node| emit_one_function(name, node) if @fast_funcs.include?(name) }
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

            @next_var += (-@next_var) % 4 # the copy moves whole words, so start on one
            @hot_base = @next_var
            @hot_bytes = @labels.fetch(HOT_END) - @labels.fetch(HOT_START)
            @next_var += @hot_bytes
            guard_fast_code_fits
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
            @fixups << { pos: pos, kind: :hot_size, reg: ACC }
            emit(ASM.load_immediate_fixed(ACC, 0)) # ...and how much, patched once it is known
            emit(ASM.load_immediate(TMP, REG_DMA3CNT))
            emit(ASM.str(ACC, TMP))
          end

          # Patch in the transfer's size and start it: whole words, both ends advancing.
          def resolve_hot_size(fix)
            words = @hot_bytes / 4
            @code[fix[:pos], 16] = ASM.load_immediate_fixed(fix[:reg], words | DMA_32BIT | DMA_ENABLE)
          end

          # Call a routine. A call that stays on one side of the cartridge/quick-memory
          # line is the plain jump it always was; one that crosses has to build the
          # address and jump through it, because the two are far too far apart for a jump
          # to reach.
          def emit_call_func(name)
            target_is_fast = @fast_funcs.include?(name)
            return emit_branch(:bl, func_label(name)) if target_is_fast == @emitting_hot

            if target_is_fast
              emit_load_fast_address(ADDR, func_label(name))
            else
              emit_load_label_address(ADDR, func_label(name))
            end
            emit(ASM.mov_reg(14, 15)) # lr = the instruction after the jump below
            emit(ASM.bx(ADDR))
          end

          # Load the quick-memory address of a label inside the moved block. Where the
          # block lands is not known until every variable has one, so this is a
          # fixed-size placeholder patched in the second pass — the same trick a
          # reference to embedded data uses.
          def emit_load_fast_address(reg, label)
            @fixups << { pos: pos, kind: :fast_addr, reg: reg, target: label }
            emit(ASM.load_immediate_fixed(reg, 0))
          end

          def resolve_fast_address(fix)
            offset = @labels.fetch(fix[:target]) - @labels.fetch(HOT_START)
            @code[fix[:pos], 16] = ASM.load_immediate_fixed(fix[:reg], @hot_base + offset)
          end

          private

          # The quick memory is 32KB and everything shares it. Growing past what is left
          # would quietly overwrite the console's own startup stack, so say so instead,
          # and say what to do about it.
          def guard_fast_code_fits
            return if @next_var <= HOT_CEILING

            over = @next_var - HOT_CEILING
            raise LoweringError,
                  "this program needs #{@next_var - IWRAM_START} bytes of the console's quick memory, " \
                  "which is #{over} more than there is. #{@hot_bytes} of it is routines kept there to " \
                  "run faster. To fix this, mark a routine `func :name, fast: false` to leave it in the " \
                  "cartridge, or build with `fast_code: false` to keep them all there."
          end

          # The routines the author named one way or the other. `fast: true` is taken as
          # an instruction and is placed before anything the framework picked; `fast:
          # false` is taken as an instruction too and is never picked.
          def funcs_marked(program, want)
            program.walk.select { |node| node.kind == :func && node[:fast] == want }
                   .map { |node| node[:name] }.to_set
          end

          # How big each routine will be once moved. A routine measured in the throwaway
          # pass can only grow, and only in one way — every call it makes to a routine
          # left behind turns into four instructions — so charging it for ALL of its calls
          # is an upper bound. Being a little pessimistic here means the last routine
          # chosen might have fitted after all; being optimistic would mean a build that
          # overruns the memory, so this is the direction to be wrong in.
          def moved_sizes(program, measured)
            calls = Hash.new(0)
            program.walk.each do |node|
              name = node.kind == :loop ? FRAME_ROUTINE : (node[:name] if node.kind == :func)
              calls[name] = node.walk.count { |child| child.kind == :call } if name
            end
            calls[IRQ_ROUTINE] = irq_bodies(program).sum { |node| node.walk.count { |c| c.kind == :call } }
            measured.to_h do |name, size|
              [name, size + (calls[name] * CROSS_CALL_GROWTH) + ROUTINE_WRAPPER]
            end
          end

          # The trees the console runs on an announcement: every bending background's block
          # and every timer's tick body. There is no one node standing for all of it the way
          # a routine has one, so the pieces are gathered.
          def irq_bodies(program)
            program.walk.select { |node| %i[scroll_rows on_timer].include?(node.kind) }
          end

          # The routines the author asked for by name, placed before anything the
          # framework picked and not held to its share of the room. Answers what is left.
          def place_insisted(program, insisted, sizes, room, chosen)
            movable = program.walk.select { |node| node.kind == :func && insisted.include?(node[:name]) }
            movable.each do |node|
              name = node[:name]
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
            ranked_by_frame_cost(program, sizes).each do |name|
              next if chosen.include?(name) || forbidden.include?(name)

              size = sizes[name]
              next if size.nil? || size > room || !movable?(program, name)

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
            else program.walk.select { |node| node.kind == :func && node[:name] == name }
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
          def ranked_by_frame_cost(program, sizes)
            model = CostModel.new
            costs = program.walk.select { |node| node.kind == :func }
                           .to_h { |node| [node[:name], model.func_frame_cost(program, node[:name])] }
            costs[FRAME_ROUTINE] = model.steady_cost(program) if sizes.key?(FRAME_ROUTINE)
            costs[IRQ_ROUTINE] = model.interrupt_frame_cost(program) if sizes.key?(IRQ_ROUTINE)

            costs.select { |name, cost| cost >= WORTH_MOVING && sizes[name].to_i.positive? }
                 .sort_by { |name, cost| [-cost, name.to_s] }.map(&:first)
          end

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

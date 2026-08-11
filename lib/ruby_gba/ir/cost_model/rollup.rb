# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # How often a frame pays for each op, and what that adds up to. {Pricing} says what
      # one op costs; this walks the program deciding how many times it happens.
      #
      # The walk is done twice over, for two different questions, and keeping them
      # straight is the whole job here:
      #
      #   #analyze     everything on the frame, as a tree of { op:, label:, cost:,
      #                children: } — the worst case, and what the drill-down shows
      #   #steady_cost what a frame really pays every time round — an every(6) body
      #                counts a sixth, a `pressed` body counts nothing, a collision walk
      #                counts only in the worst case
      #
      # Loops multiply, a scene dispatch takes its heaviest branch (only one runs a
      # frame), and a call is its target inlined. A repeat over a list counts up to the
      # list's capacity; a repeat whose count is only known at run time has no provable
      # bound, so it counts as zero and is reported as a blind spot rather than guessed
      # at (see {Verdicts}).
      module Rollup
        # The draw work of one frame as a structured cost tree: an array of nodes
        # { op:, label:, cost:, children: }. It's the game loop's body if there is
        # one, otherwise the one-time boot draws of a static program. Costs roll up:
        # a container's cost is the sum of its children (a repeat multiplies, a
        # case_var takes its worst branch).
        def analyze(program, focus: nil)
          index(program)
          if focus
            func = @funcs.fetch(focus)
            @stack.push(focus)
            return func.children.flat_map { |node| build(node) }
          end
          loop_node = program.children.find { |node| node.kind == :loop }
          statements = loop_node ? loop_node.children : program.children.reject { |node| node.kind == :func }
          in_fast_frame { statements.flat_map { |node| build(node) } }
        end

        # The total draw cost of one frame — the roll-up of #analyze. This is the
        # *full* cost of everything on the frame, ignoring how often it runs.
        def frame_cost(program)
          analyze(program).sum(&:cost)
        end

        # The whole per-frame cost that actually recurs *every* frame (drawing, logic,
        # and sound) — the 60fps load. Cost hints scale work down: an every(k) body
        # counts 1/k, a transition-guarded body counts 0, and so on. Untagged work
        # weighs 1, so a program with no hints has steady_cost == frame_cost. For the
        # tear risk use #steady_tear_cost.
        def steady_cost(program)
          in_fast_frame { steady_statements(program).sum { |node| steady(node) } }
        end

        # WHAT RACES THE SAFE WINDOW, which is the tear risk: everything the frame does from
        # the moment the screen is ready up to and including the LAST thing it draws.
        #
        # The window is about sixty-eight lines, and a frame's body starts at the top of it.
        # What tears the picture is a write to video memory landing after the window has
        # closed — so what matters is not how much of the body DRAWS, it is how much of the
        # body happens BEFORE the last draw. Work that draws nothing delays that draw exactly
        # as surely as work that does, and the console agrees: a thousand passes of plain
        # arithmetic ahead of one pixel puts that pixel on scanline 11, in the middle of the
        # visible picture.
        #
        # Counting the drawing alone would not do it. "Only drawing can tear" is true of the
        # WRITE and false of the DEADLINE, and a frame can spend the whole window thinking.
        #
        # Work AFTER the last draw is left out, and that is not a rounding: nothing is drawn
        # after it, so it cannot push a write anywhere. A game that draws first and thinks
        # afterwards really is safer than one that does it the other way round, and this is
        # the one number that says so.
        def steady_tear_cost(program)
          statements = steady_statements(program)
          last = statements.rindex { |node| draws?(node) }
          return 0 unless last

          in_fast_frame { statements[0..last].sum { |node| steady(node) } }
        end

        # Whether anything in this statement draws, following a call or a scene dispatch into
        # the routine it runs — a frame's drawing is nearly always behind one of those.
        def draws?(node, seen = [])
          return false if node.kind == :func
          return true if DRAW_KINDS.include?(node.kind)

          case node.kind
          when :call then func_draws?(node.target, seen)
          when :case then node.clauses.any? { |_value, target| func_draws?(target, seen) }
          else
            node.children.any? { |child| draws?(child, seen) } ||
              (node.branching? && !node.else.nil? && draws?(node.else, seen))
          end
        end

        def func_draws?(name, seen)
          return false if seen.include?(name)

          func = @funcs[name] or return false
          seen.push(name)
          func.children.any? { |child| draws?(child, seen) }
        ensure
          seen.pop if func
        end

        # The statements that make up a frame — a game loop's body, or a static
        # program's top-level draws (funcs excluded; they're counted where called).
        def steady_statements(program)
          index(program)
          loop_node = program.children.find { |node| node.kind == :loop }
          loop_node ? loop_node.children : program.children.reject { |node| node.kind == :func }
        end

        # What one pass through a named routine costs — its own statements, its loops
        # multiplied out, and the routines it calls. This is what a backend ranks by when
        # it decides which routines are worth keeping in faster memory (see
        # Backends::GBA::Placement).
        #
        # It is a pass, not a frame: a routine reached once a frame is priced exactly,
        # and one behind an `every(6)` is priced as though it ran every frame. That errs
        # generously toward a routine that runs sometimes, which is the safe way to be
        # wrong when the answer only picks an ORDER.
        def func_frame_cost(program, name)
          index(program)
          steady_func(name)
        end

        private

        # The selectivity-weighted cost of a subtree: how often the node's body
        # actually runs scales its cost, so what's left is the work that runs every
        # frame. A node that always runs weighs 1 (see #selectivity).
        # +worst+ runs the same walk asking for everything a frame could cost rather than
        # what it usually does — see #expr_cost. Differencing the two is how the estimate
        # names what the recurring load leaves out.
        #
        # It counts EVERYTHING a node does, drawing and logic alike, because both deadlines a
        # frame races are decided that way: the frame rate by the whole of it, and the tear
        # risk by the whole of it up to the last draw (#steady_tear_cost). There is nothing
        # here that sums the drawing on its own.
        def steady(node, worst: false)
          selectivity(node) * raw_steady(node, worst)
        end

        def raw_steady(node, worst)
          case node.kind
          when :program, :loop, :else then node.children.sum { |child| steady(child, worst: worst) }
          # The condition is tested every frame, whichever way it goes — that's where a
          # collision test's comparison chain lives — so it's priced here; only the branch
          # bodies are scaled by how often they run.
          when :if
            expr_cost(node.cond, worst: worst) +
              node.children.sum { |child| steady(child, worst: worst) } +
              (node.else ? steady(node.else, worst: worst) : 0)
          # A loop costs a rate per pass AND a fixed amount for being entered — see
          # #loop_overhead_leaf for what each of them is.
          when :repeat
            body = node.children.sum { |child| steady(child, worst: worst) }
            # A walk over a list counts at what the list USUALLY holds here, where the tree
            # above counts it at the capacity: this is the every-frame load, and no frame
            # pays for a list it has not filled (see #repeat_factor).
            passes = repeat_factor(node, typical: true).first
            (passes * (body + loop_pass_cost(node))) +
              (passes.positive? ? loop_start_cost(node) : 0)
          # A timed trigger's steady per-frame cost follows from its kind: every(k)
          # runs one frame in k, so its body counts 1/k; after(n) fires once ever, so
          # it adds nothing to the every-frame load.
          when :every
            Rational(1, node.period) * node.children.sum { |child| steady(child, worst: worst) }
          when :after then 0
          when :case then node.clauses.map { |_value, target| steady_func(target, worst: worst) }.max || 0
          when :call then steady_func(node.target, worst: worst)
          when :func then 0
          else op_cost(node, worst: worst)
          end
        end

        def steady_func(name, worst: false)
          return 0 if @stack.include?(name)
          func = @funcs[name] or return 0
          @stack.push(name)
          total = in_fast_memory(name) { func.children.sum { |child| steady(child, worst: worst) } }
          @stack.pop
          total
        end

        # Run a block as though it were inside a routine that lives in faster memory, so
        # every op it prices is charged at what it really costs there (see
        # Pricing#fast_memory_factor). Nested routines that also moved change nothing —
        # they are inside the same block of memory and are already being charged for it.
        def in_fast_memory(name)
          return yield unless @fast_routines.include?(name)

          in_fast_code { yield }
        end

        # The same, for the frame's own body — which is a routine to the machine once it
        # has been moved, but has no name in the program to be found by.
        def in_fast_frame
          return yield unless @fast_frame

          in_fast_code { yield }
        end

        # And for the routine an announcement from the display or a timer is answered in,
        # which likewise has no name in the program.
        def in_fast_interrupts
          return yield unless @fast_interrupts

          in_fast_code { yield }
        end

        def in_fast_code
          was = @in_fast_code
          @in_fast_code = true
          yield
        ensure
          @in_fast_code = was
        end

        # How often an `if`'s body runs, read from its condition: a body behind a
        # `pressed` edge is a rare transition (never counts toward the steady load); a
        # `chance(p)` body holds p% of the time. A `held` or a plain comparison runs
        # every frame it's true, so it weighs 1 — as does any non-`if` node.
        def selectivity(node)
          return 1 unless node.kind == :if

          case node.cond&.kind
          when :pressed then 0
          when :chance then Rational(node.cond.percent, 100)
          else 1
          end
        end

        # What every per-pixel collision test in a frame costs if they all land at once —
        # the part of the worst case the recurring load leaves out, so the estimate can say
        # so out loud rather than just showing a bigger number further down.
        def collision_worst_case(program)
          statements = steady_statements(program)
          everything = statements.sum { |node| steady(node, worst: true) }
          everything - statements.sum { |node| steady(node) }
        end

        # Catalogue the funcs (so a `call`/`case` can be costed), the list capacities
        # (so a repeat over a list can be bounded), the songs (so a `play_song` can be
        # costed by its note count), the bitmaps (so a `blit` can be costed by its
        # image's size, which lives on the definition, not the blit op), and the sprites
        # (so drawing one can be costed by whether it turns or resizes, which likewise
        # lives on the declaration and not on the draw).
        #
        # Every analysis starts here, so the walk's own state — which routines it is
        # inside, and which screen each of them draws on — is reset here too.
        def index(program)
          @unpriced = [] # kinds seen with no estimate — reset each analysis (see #unpriced_kinds)
          @stack = []
          @modes = resolve_modes(program)
          @funcs = {}
          @capacities = {}
          @declared = {}
          @list_lengths = {}
          @table_lengths = {}
          @songs = {}
          @bitmaps = {}
          @backing = {}
          @objects = {}
          program.walk do |node|
            @funcs[node.name] = node if node.kind == :func
            @capacities[node.name] = node.capacity if node.kind == :list_new
            # ...and the length the AUTHOR asked for, which is the most the list can really
            # reach. The ring rounds its size up to a power of two, and that headroom is for
            # the mask rather than for the game (see Build#list_new).
            @declared[node.name] = node.declared || node.capacity if node.kind == :list_new
            # ...and how long the author says it usually is, which is a different question
            # and the only one a frame's real cost turns on (see #list_length).
            @list_lengths[node.name] = node.usually if node.kind == :list_new && node.usually
            # How long a table is decides what a read of it costs, so it is read once here
            # from the declaration rather than at every read (see Pricing#table_read_weight).
            @table_lengths[node.name] = node.values.length if node.kind == :table
            @songs[node.name] = node if node.kind == :song
            @bitmaps[node.name] = catalogue_bitmap(node) if node.kind == :bitmap
            @objects[node.name] = catalogue_object(node) if node.kind == :object
            @backing[node.name] = [node.width, node.height] if node.kind == :backing_buffer
          end
        end

        # What drawing one sprite costs, in the two ways a sprite can be more than a
        # position: it can be turned to an angle, and it can be drawn at a size. Both are
        # settled on the declaration — a sprite that never turns keeps a fixed angle
        # there — so they are read once here rather than at every frame's draw.
        def catalogue_object(node)
          turns = !constant_operand?(node.angle, 0)
          Sprite.new(turns: turns || resizes?(node), resizes: resizes?(node))
        end

        def resizes?(node) = !constant_operand?(node.scale, Build::SCALE_ONE)

        def constant_operand?(node, value)
          node.kind == :int && node.value == value
        end

        # What an image costs to draw, worked out once here rather than at every blit of
        # it. An image with no see-through color streams onto the screen in whole rows and
        # is priced by its size alone.
        #
        # One WITH a see-through color is drawn a pixel at a time, and then three numbers
        # matter. How many pixels are actually LIT (a see-through one is never written).
        # How many ROWS hold at least one (a row with none is skipped whole). And how many
        # of the lit pixels carry a color that needs a step of its own to build — because
        # drawing a pixel at a time means writing the color into every store, and only some
        # colors fit inside that instruction.
        #
        # Counting them is what stops a sprite that is mostly cut-out background from being
        # priced as a solid rectangle.
        def catalogue_bitmap(node)
          see_through = node.transparent
          width = node.width
          height = node.height
          unless see_through
            return Bitmap.new(width: width, height: height, transparent: false,
                              lit_pixels: width * height, wide_color_pixels: 0, lit_rows: height)
          end

          # The pixels arrive as a run of 16-bit colors, row after row.
          rows = node.pixels.unpack("v*").each_slice(width).map { |row| row.reject { |px| px == see_through } }
          Bitmap.new(width: width, height: height, transparent: true,
                     lit_pixels: rows.sum(&:length),
                     wide_color_pixels: rows.sum { |row| row.count { |px| wide_color?(px) } },
                     lit_rows: rows.count { |row| !row.empty? })
        end

        # Whether a color has to be built in a step of its own instead of riding inside the
        # instruction that writes it. The assembler makes this exact call every time it
        # loads a constant, so it is asked rather than restated here.
        def wide_color?(color) = ASM.encode_rotated_immediate(color).nil?

        # Which screen each routine of the program draws on. A program that reaches one
        # drawing routine from two different screens can't be lowered at all, so there is
        # no mode to read and no cost to quote either — the build will say so, and every
        # op falls back to the boot screen here rather than guessing.
        def resolve_modes(program)
          Modes.resolve(program)
        rescue Modes::Conflict
          nil
        end

        # The screen the op being priced draws on: the mode of the routine the walk is
        # inside, or the boot mode at the top level. A game can put a direct-color title
        # and a tear-free play field in one program, and the SAME verb costs very
        # different things on the two — so which one is being priced has to be known
        # before the price is (see Pricing#own_op_cost).
        def current_mode
          return Modes::DIRECT unless @modes

          @stack.last ? @modes.mode_of(@stack.last) : @modes.default_mode
        end

        # Whether the op being priced draws on the tear-free (double-buffered) screen,
        # which holds a pixel as one byte and can't write a lone one — so it draws
        # everything in a different shape from the direct-color screen.
        def tear_free? = current_mode == Modes::BUFFERED

        # Build the cost tree for a node — an array (if/else/program are transparent
        # and splice their children; a non-draw leaf contributes nothing).
        def build(node)
          case node.kind
          when :program, :loop then node.children.flat_map { |child| build(child) }
          when :if
            # The test itself runs every frame, whichever way it branches, so its cost is
            # real per-frame work and shown as its own leaf — a per-pixel collision test
            # especially is not free. Then the branches.
            condition_leaf(node.cond) + (node.children + [node.else].compact).flat_map { |child| build(child) }
          when :else then node.children.flat_map { |child| build(child) }
          when :case then [build_case(node)]
          when :call then [build_call(node)]
          when :repeat then [build_repeat(node)]
          when :every then [build_timer(node, "every #{node.period}")]
          when :after then [build_timer(node, "after #{node.frames}")]
          when :func then [] # a definition: it costs only where it's called
          else build_leaf(node)
          end
        end

        # A branch test as a cost leaf — the work of evaluating an `if`'s condition every
        # frame. Only shown when it isn't free (a comparison and up cost something; a bare
        # variable read doesn't). A collision (`overlaps?`) reads as "collision test", since
        # its per-pixel half is the expensive part; anything else reads as "test".
        def condition_leaf(cond)
          c = expr_cost(cond)
          return [] unless c.positive?

          arithmetic = arithmetic_leaves(cond, category: :logic, source: nil)
          own = c - sum(arithmetic)
          return arithmetic unless own.positive?

          collision = cond.walk.any? { |n| n.kind == :pixels_overlap }
          name = collision ? "collision test" : "test"
          arithmetic + [Entry.new(op: collision ? :collision : :cond, name: name, label: name, cost: own)]
        end

        # A drawing or compute op becomes a leaf, with the dear arithmetic it was handed
        # split out ahead of it — the arithmetic runs before the statement can, and reads
        # that way. Anything that costs nothing at all is dropped.
        def build_leaf(node)
          c = op_cost(node)
          return [] unless c.positive?

          arithmetic = arithmetic_leaves(node, category: category_of(node.kind), source: node.source)
          arithmetic + statement_leaf(node, c - sum(arithmetic))
        end

        # A statement's own leaf: what it costs once the arithmetic it was handed is
        # counted separately. None at all when its own work is free, so a statement that
        # is nothing but its arithmetic leaves only the arithmetic behind.
        # w/h ride along so aggregation can tell a 33x60 stripe from a 4x4 corner
        # (they're nil for pixel/clear/text, which then all fold together).
        def statement_leaf(node, cost)
          return [] unless cost.positive?

          # A rectangle's size rides along so aggregation can tell a 33x60 stripe from a 4x4
          # corner; a pixel, a clear or a text draw has no size and they all fold together.
          size = node.sized? ? { w: node.w, h: node.h } : {}
          [Entry.new(op: node.kind, label: label_of(node), cost: cost, source: node.source, **size)]
        end

        # The arithmetic a statement or a test does before it can run, as cost leaves of
        # its own — everything dearer than a plain step, named for a reader. This is what
        # stops a divide from hiding inside the statement it sits in: `set :height,
        # WALL / distance` is one `set` in the tree and the divide is nearly all of what
        # it costs, so showing the `set` alone shows a number with no name on it. An add,
        # a compare, a shift stay folded into their statement, where they belong.
        #
        # A leaf carries the section and the call site of the statement it came from, so
        # pulling it out never moves cost between the drawing / sound / logic sections or
        # between files — it only names what was already counted there.
        def arithmetic_leaves(value, category:, source:, out: [])
          return out unless value.is_a?(Node)

          if (kind = arithmetic_kind(value))
            out << Entry.new(op: kind.op, name: kind.name, label: kind.name,
                             cost: own_cost(value, true), category: category, source: source)
          end
          value.attrs.each_value do |slot|
            items = slot.is_a?(Array) ? slot : [slot]
            items.each { |item| arithmetic_leaves(item, category: category, source: source, out: out) }
          end
          out
        end

        # case_var runs one scene per frame, so its cost is the heaviest branch. Every
        # branch is still shown — a reader wants to see the light scenes too — but only
        # the heaviest carries a frame's worth of work, which is what `factor` says (see
        # Tree#weigh_leaves).
        def build_case(node)
          branches = node.clauses.map do |value, target|
            kids = func_children(target)
            Entry.new(op: :branch, label: "#{value} -> :#{target}", cost: sum(kids), children: kids)
          end
          worst = branches.max_by(&:cost)
          Entry.new(op: :case, label: "case_var :#{node.var}", cost: worst&.cost || 0, source: node.source,
                    children: branches.map { |b| b.with(factor: b.equal?(worst) ? 1 : 0) })
        end

        # A call is its target func's body, inlined (guarding against a call cycle).
        def build_call(node)
          kids = func_children(node.target)
          Entry.new(op: :call, label: "call :#{node.target}", cost: sum(kids), source: node.source,
                    children: kids)
        end

        # A repeat runs its body count times, so its cost multiplies — and so does the
        # cost of going round, which leads the body because that is when it happens.
        def build_repeat(node)
          factor, note = repeat_factor(node)
          kids = loop_overhead_leaf(node, factor) + node.children.flat_map { |child| build(child) }
          Entry.new(op: :repeat, label: "repeat #{note}", cost: factor * sum(kids), factor: factor,
                    source: node.source, children: kids)
        end

        # WHAT A LOOP COSTS BESIDE ITS BODY, as one line, because it is one thing to a reader:
        # the work that is there because this is a loop.
        #
        # It is two costs that scale differently. Each PASS counts, tests the count and jumps
        # back — small, about three plain steps, but paid once per pass, so a loop of six
        # hundred pays it six hundred times. And ENTERING the loop costs about twenty
        # instructions once: working the trip count out into the loop's hidden limit, zeroing
        # its counter, and the branch that leaves.
        #
        # The entering is shared out over the passes here, so the container above can go on
        # being the sum of its children times the trip count. That division is also what makes
        # the line say the useful thing: a loop of four reads several times dearer a pass than
        # a loop of four hundred, because it is — most of a short loop is being a loop.
        #
        # The line also says WHICH SHAPE the loop got, and when it got the slow one, what in
        # the body stopped it having the other. That is the one thing an author can act on: a
        # call moved out of a loop is worth three quarters of what the loop costs.
        def loop_overhead_leaf(node, factor)
          each = loop_pass_cost(node) + (factor.positive? ? loop_start_cost(node) / factor : 0)
          [Entry.new(op: :loop_pass, name: loop_overhead_name(node),
                     label: loop_overhead_label(node), cost: each)]
        end

        # The name the hottest list groups on carries the SHAPE but not the per-loop reason.
        # A program's loops rarely all get the same shape, and the tree row for a hot one is
        # often collapsed behind a call, so rolling every loop into one line would hide the
        # thing worth knowing: how much of the frame goes on loops that could not hold their
        # counter. The tree line adds the reason for each.
        def loop_overhead_name(node)
          shape = loop_shape(node)
          return "the loop itself" unless shape

          "the loop itself (#{SHAPE_NAMES.fetch(shape.shape)})"
        end

        SHAPE_NAMES = { registers: "in registers", spilled: "in registers, saved and put back",
                        memory: "through memory" }.freeze

        # The tree line says the shape AND what in the body made it that shape, because that is
        # the one thing an author can act on. A spilled loop names it too: the statement it has
        # to save the registers around is the statement to move out of the loop, and doing so
        # takes the saving away as well.
        def loop_overhead_label(node)
          shape = loop_shape(node)
          return "the loop itself" unless shape
          return "the loop itself (in registers)" if shape.shape == :registers

          "the loop itself (#{SHAPE_NAMES.fetch(shape.shape)} — #{shape.blocked_by})"
        end

        # WHICH SHAPE THIS LOOP GOT, which is the BUILD'S answer and is handed over rather than
        # worked out again here — the same arrangement as where each variable landed.
        #
        # It has to be. Whether a loop can keep its counter in a register is a fact about
        # registers, and registers belong to a lowering; this file prices what a lowering
        # produced and must not start deciding for it. A program handed straight to the model,
        # or a guardrail asking before anything has been lowered, has no map — and then every
        # loop is priced as the safe shape, which is the dearer of the two and the right way to
        # be wrong.
        def loop_shape(node) = @loop_shapes[node.index]

        # A loop that keeps its counter in a register is four instructions a pass where one
        # through memory is sixteen, so the two are priced apart.
        def held_loop?(node) = loop_shape(node)&.held || false

        # Both halves are instructions like any other, so both are charged less where the code
        # runs faster.
        #
        # A loop that keeps its count in registers by SAVING the pair around what would land in
        # them pays for each save, every pass — that is the whole trade, and leaving it out
        # would make the shape look free and the build's choice look better than it is.
        def loop_pass_cost(node)
          (@weights[held_loop?(node) ? :loop_pass_held : :loop_pass] + spill_cost(node)) *
            fast_memory_factor
        end

        def spill_cost(node)
          shape = loop_shape(node)
          return 0 unless shape&.spilled?

          shape.spills * @weights[:loop_spill]
        end

        def loop_start_cost(node)
          @weights[held_loop?(node) ? :loop_start_held : :loop_start] * fast_memory_factor
        end

        # A timed trigger (every/after) as a labeled container: it carries its body's
        # full cost — the cost of the frame it does fire — so the tree and the
        # heaviest-frame figure read true; the steady discount is applied separately
        # (see #raw_steady). The label names the intent, e.g. "every 30".
        def build_timer(node, label)
          kids = node.children.flat_map { |child| build(child) }
          Entry.new(op: node.kind, label: label, cost: sum(kids), source: node.source, children: kids)
        end

        def func_children(name)
          return [] if @stack.include?(name)
          func = @funcs[name] or return []
          @stack.push(name)
          kids = in_fast_memory(name) { func.children.flat_map { |child| build(child) } }
          @stack.pop
          kids
        end

        def sum(nodes) = nodes.sum(&:cost)

        # How many times a repeat runs, and a human note: a literal count exactly; a
        # list's length up to its capacity (the most it can hold). An unknown count
        # (a plain variable) has no provable bound, so it contributes zero to the
        # estimate and is noted as unbounded rather than guessed.
        #
        # +typical+ asks the other question about a list: not the most a walk over it could
        # ever cost, but what it costs on the frames a game actually plays. The capacity is
        # the only bound a build can prove, so it is the right ceiling and the wrong typical
        # — a snake's body list is sized for every cell of the board and holds four cells
        # for most of a game, so the two answers are a hundred times apart. Counting the
        # ceiling as the every-frame load is what made a snake that measures 49 scanlines
        # report 106 of its 228.
        def repeat_factor(node, typical: false)
          count = node.count
          return [count.value, "x#{count.value}"] if count.is_a?(Node) && count.kind == :int
          if count.is_a?(Node) && count.kind == :list_len && @capacities[count.name]
            cap = @capacities[count.name]
            return [cap, "x<=#{cap} (#{count.name} capacity)"] unless typical && !@at_list_capacity

            usual = list_length(count.name)
            return [usual, "x#{usual} (#{count.name} usually)"]
          end
          [0, "x? (unbounded)"]
        end

        # Ask the every-frame question about a list AS THOUGH IT WERE FULL, for the length
        # of a block. One caller wants that: the guardrail that says at what length a
        # growing list stops fitting in a frame (see Verdicts#budget_thresholds) is asking
        # about the frames a game has not reached yet, which is the one question the typical
        # length is the wrong answer to.
        def at_list_capacity
          was = @at_list_capacity
          @at_list_capacity = true
          yield
        ensure
          @at_list_capacity = was
        end

        # HOW LONG A LIST USUALLY IS, which nothing in a program says out loud.
        #
        # The author can say it (`list :body, capacity: 256, estimate: { usually: 12 }`) and
        # then this is simply what they said. Where they have not, it is a guess and the
        # report says so:
        # a QUARTER of the capacity, because a capacity is picked as a ceiling the list must
        # never pass and is then rounded up to a power of two, so it already sits above the
        # biggest number the author had in mind. A quarter of it is still a real walk — it
        # counts every pass — and it is nearer the truth than the ceiling for every list a
        # game grows into.
        #
        # Guessing at all is a deliberate call. The alternative is to keep charging the
        # ceiling, and that is not the safe direction here: it is not a couple of
        # instructions over, it is a hundred times over on the one line that dominates the
        # frame, and an estimate that cries wolf on a game which fits teaches an author to
        # stop reading it. The worst case is still counted and still printed — see the tree,
        # which keeps the capacity, and the line the report prints beside the verdict.
        UNSAID_LIST_SHARE = 4

        def list_length(name)
          @list_lengths[name] || [@capacities[name] / UNSAID_LIST_SHARE, 1].max
        end
      end
    end
  end
end

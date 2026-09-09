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
      #
      # Everything about WHERE the walk is right now — which routines it is nested
      # inside, how tall the area it is drawing into is, whether the code it is pricing
      # runs from faster memory, whether a list is being counted at its worst — lives
      # here and only here: +@stack+, +@draw_height+, +@in_fast_code+,
      # +@at_full_capacity+ are never read from outside this class. Rollup (see
      # rollup.rb) exposes these same method names as one-line forwards to a Walker
      # instance built fresh by every #index, so nothing outside cost_model/ has to
      # know Walker exists to reach them.
      #
      # +pricing+ answers #op_cost / #expr_cost / #own_cost / #arithmetic_kind /
      # #const_side / #fast_memory_factor; +tree+ answers #label_of — how a priced leaf
      # reads to a person, {Tree}'s job, not this one's (#category_of needs no instance
      # and is called on the class directly, Tree.category_of). Both +pricing+ and
      # +tree+ are wired in AFTER construction (see #pricing=/#tree=) rather than taken
      # as constructor arguments, because the dependency runs the other way too:
      # {Pricing} needs a Walker to ask #current_mode/#tear_free? of, and {Tree}'s own
      # #category_tree calls back into #analyze — so whichever of the three is built
      # first has to exist before the other two can be, and a Walker is what the other
      # two are built from.
      class Walker
        attr_writer :pricing, :tree

        def initialize(catalogue:, weights:, fast_routines:, fast_frame:, fast_interrupts:, loop_shapes:)
          @catalogue = catalogue
          @weights = weights
          @fast_routines = fast_routines
          @fast_frame = fast_frame
          @fast_interrupts = fast_interrupts
          @loop_shapes = loop_shapes
          @stack = []
          @loops = []
          @in_fast_code = false
          @at_full_capacity = false
          @draw_height = nil
        end

        # A fresh #index mid-walk (steady_cost called from inside an at_full_capacity
        # block, say) rebuilds the catalogue and resets the call stack — exactly what
        # the original #index did — but leaves the walk's own toggles alone. They're
        # holding a caller's intent (at_full_capacity, in_fast_code, the current area's
        # height) that a re-index in the middle of it must not silently drop.
        def reindex(catalogue)
          @catalogue = catalogue
          @stack = []
          @loops = []
        end

        # The repeats the walk is inside right now, innermost last — so a price can ask whether
        # a list is being read by a loop's own counter (see Pricing#list_read_weight).
        def within_loop(node)
          @loops.push(node)
          yield
        ensure
          @loops.pop
        end

        # The repeat the walk is inside whose counter is +name+, or nil when +name+ is not a
        # counter of any enclosing loop. Which shape that loop got says what a read by its
        # counter costs (see #held_loop?).
        def loop_counted_by(name)
          @loops.find { |loop| loop.index == name }
        end

        # The draw work of one frame as a structured cost tree: an array of nodes
        # { op:, label:, cost:, children: }. It's the game loop's body if there is
        # one, otherwise the one-time boot draws of a static program. Costs roll up:
        # a container's cost is the sum of its children (a repeat multiplies, a
        # case_var takes its worst branch).
        def analyze(program, focus: nil)
          if focus
            func = @catalogue.funcs.fetch(focus)
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

          func = @catalogue.funcs[name] or return false
          seen.push(name)
          func.children.any? { |child| draws?(child, seen) }
        ensure
          seen.pop if func
        end

        # The statements that make up a frame — a game loop's body, or a static
        # program's top-level draws (funcs excluded; they're counted where called).
        def steady_statements(program)
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
        def func_frame_cost(name)
          steady_func(name)
        end

        # What a subtree really costs every frame: how often a body actually runs scales it,
        # so what is left is the work a frame always pays for (see #selectivity).
        # +worst+ runs the same walk asking for everything a frame could cost rather than
        # what it usually does — see #expr_cost. Differencing the two is how the estimate
        # names what the recurring load leaves out.
        #
        # It counts EVERYTHING a node does, drawing and logic alike, because both deadlines a
        # frame races are decided that way: the frame rate by the whole of it, and the tear
        # risk by the whole of it up to the last draw (#steady_tear_cost). There is nothing
        # here that sums the drawing on its own.
        def steady(node, worst: false)
          case node.kind
          # An area costs nothing of its own — it is edges the shapes below cut themselves
          # against, not work — so its children are counted exactly as they would be anywhere.
          # It does bound one of them: a stretched column is clipped to it.
          when :program, :loop, :else
            node.children.sum { |child| steady(child, worst: worst) }
          when :inside
            within_area(node) { node.children.sum { |child| steady(child, worst: worst) } }
          # The condition is tested every frame, whichever way it goes — that's where a
          # collision test's comparison chain lives, and a pool's walk asks whether a slot is
          # live on every slot it has — so it's priced whole here; only the branch bodies are
          # scaled by how often they run.
          when :if
            @pricing.expr_cost(node.cond, worst: worst) + branch_cost(node, worst: worst)
          # A loop costs a rate per pass AND a fixed amount for being entered — see
          # #loop_overhead_leaf for what each of them is.
          when :repeat
            body = within_loop(node) { node.children.sum { |child| steady(child, worst: worst) } }
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
          else @pricing.op_cost(node, worst: worst)
          end
        end

        def steady_func(name, worst: false)
          return 0 if @stack.include?(name)
          func = @catalogue.funcs[name] or return 0
          @stack.push(name)
          total = in_fast_memory(name) { func.children.sum { |child| steady(child, worst: worst) } }
          @stack.pop
          total
        end

        # Price a routine's body where that routine actually lives, so every op in it is
        # charged what it really costs there (see Pricing#fast_memory_factor).
        #
        # WHERE IT LIVES IS ITS OWN BUSINESS, not its caller's, and that is the whole point
        # of this. A routine is emitted once and jumped to, so a routine left in the
        # cartridge runs from the cartridge even when the frame's own body — which called
        # it — was moved into quick memory. Reading this the other way round says a game
        # gets quick memory it does not have: a frame body that moved would carry its
        # speed into every routine it reached, and a report of what the build KEPT would
        # cost the same as a report of what it turned away.
        def in_fast_memory(name)
          in_code(fast: @fast_routines.include?(name)) { yield }
        end

        # The same, for the frame's own body — which is a routine to the machine once it
        # has been moved, but has no name in the program to be found by.
        def in_fast_frame
          return yield unless @fast_frame

          in_code(fast: true) { yield }
        end

        # And for the routine an announcement from the display or a timer is answered in,
        # which likewise has no name in the program.
        def in_fast_interrupts
          return yield unless @fast_interrupts

          in_code(fast: true) { yield }
        end

        def in_code(fast:)
          was = @in_fast_code
          @in_fast_code = fast
          yield
        ensure
          @in_fast_code = was
        end

        # Whether the code being priced right now runs from the console's quick memory —
        # the seam Pricing reaches through rather than reading @in_fast_code itself (see
        # Pricing#fast_memory_factor).
        def in_fast_code? = @in_fast_code

        # HOW TALL THE PART OF THE SCREEN BEING DRAWN INTO IS, while walking an `inside` block.
        # Only one thing reads it — a stretched column, whose height the game works out and which
        # is CLIPPED to this, so the area is what bounds it (see Pricing#column_rows). Everything
        # else an area holds is priced from its own numbers, so the area costs nothing and says
        # nothing. Areas do not nest, so this needs no stack.
        def within_area(node)
          was = @draw_height
          @draw_height = @pricing.const_side(node.h)
          yield
        ensure
          @draw_height = was
        end

        # The height of the area being drawn into right now, or nil outside one — the
        # other seam Pricing reaches through rather than reading @draw_height itself
        # (see Pricing#column_rows).
        def draw_height = @draw_height

        # How often an `if`'s body runs. A body behind a `pressed` edge is a rare transition
        # (never counts toward the steady load); a `chance(p)` body holds p% of the time; a
        # test that guards one slot of a walk holds for the slots in use (see #live_share).
        # A `held` or a plain comparison runs every frame it's true, so it weighs 1 — as does
        # any non-`if` node.
        # WHAT THE ARMS OF A BRANCH COST A FRAME. Only one of them runs.
        #
        # Charging the share times BOTH arms added together is not caution — it is
        # arithmetic that cannot be right. An `if/else` runs one arm or the other, so a
        # renderer that draws a wall one way and a door the other would be charged for
        # two walls every strip of every frame, and that doubling lands squarely on the
        # most expensive line in a first-person game — nearly doubling the whole frame
        # estimate on Wolfenstein.
        #
        # WHEN THE SHARE IS KNOWN — a `chance(25)`, a `pressed` edge, a walk over slots that says
        # how many are usually live — the two arms are weighted by it, which is what an average
        # frame really pays. When it is not known, neither arm can be ruled out, so the dearer
        # of the two is charged: the honest answer to "one of these runs and nothing here can say
        # which", and never less than the console spends.
        def branch_cost(node, worst:)
          taken = node.children.sum { |child| steady(child, worst: worst) }
          return selectivity(node) * taken unless node.else

          other = steady(node.else, worst: worst)
          return [taken, other].max unless known_share?(node)

          share = selectivity(node)
          (share * taken) + ((1 - share) * other)
        end

        # Whether anything in the program says how often this branch goes one way. A plain
        # comparison does not; an edge, a chance, and a walk that was told how many slots are
        # live all do.
        def known_share?(node)
          return true if node.of

          %i[pressed chance].include?(node.cond&.kind)
        end

        def selectivity(node)
          return 1 unless node.kind == :if
          return @at_full_capacity ? 1 : live_share(node) if node.of
          # What the author said: this body runs on `runs` frames in every `per`. The worst
          # frame is one where it DOES run, so a worst-case walk ignores it — the same way
          # a list's usual length gives way to its capacity.
          return @at_full_capacity ? 1 : Rational(node.runs, node.per) if node.runs

          case node.cond&.kind
          when :pressed then 0
          when :chance then Rational(node.cond.percent, 100)
          else 1
          end
        end

        # WHAT SHARE OF A WALK'S SLOTS ARE IN USE, for a guard that says it is one.
        #
        # A pool walks every slot it has — that is real work, the test is asked of each one,
        # and it is priced above whatever this returns. But the body behind the test is only
        # for a live slot, and a pool is sized for the worst moment of a game rather than a
        # normal one: sixty-four bullets so the one frame that needs sixty-four has them, six
        # on screen the rest of the time. Counting sixty-four bodies a frame is counting ten
        # times the work the console does.
        #
        # The author can say the number (`estimate: { usually: 6 }`) and then this is simply
        # what they said. Where they have not it is a guess, named as one in the report, and
        # it is the same quarter a list's unsaid length guesses — for the same reason, and
        # the reason is the same shape of mistake: a capacity is chosen so it can never be
        # reached, so it sits above anything the author had in mind.
        def live_share(node)
          Rational(node.usually || unsaid_share(node.of), node.of)
        end

        def unsaid_share(slots) = [slots / UNSAID_SHARE, 1].max

        # What every per-pixel collision test in a frame costs if they all land at once —
        # the part of the worst case the recurring load leaves out, so the estimate can say
        # so out loud rather than just showing a bigger number further down.
        def collision_worst_case(program)
          statements = steady_statements(program)
          everything = statements.sum { |node| steady(node, worst: true) }
          everything - statements.sum { |node| steady(node) }
        end

        # The screen the op being priced draws on: the mode of the routine the walk is
        # inside, or the boot mode at the top level. A game can put a direct-color title
        # and a tear-free play field in one program, and the SAME verb costs very
        # different things on the two — so which one is being priced has to be known
        # before the price is (see Pricing#own_op_cost).
        def current_mode
          return Modes::DIRECT unless @catalogue.modes

          @stack.last ? @catalogue.modes.mode_of(@stack.last) : @catalogue.modes.default_mode
        end

        # Whether the op being priced draws on the tear-free (double-buffered) screen,
        # which holds a pixel as one byte and can't write a lone one — so it draws
        # everything in a different shape from the direct-color screen.
        def tear_free? = current_mode == Modes::BUFFERED

        # Build the cost tree for a node — an array (if/else/program are transparent
        # and splice their children; a non-draw leaf contributes nothing).
        def build(node)
          case node.kind
          # An area is see-through to the report as well: what it holds is what it costs, and
          # a reader wants to see the shapes, not a box round them.
          when :program, :loop then node.children.flat_map { |child| build(child) }
          when :inside then within_area(node) { node.children.flat_map { |child| build(child) } }
          when :if
            # The test itself runs every frame, whichever way it branches, so its cost is
            # real per-frame work and shown as its own leaf — a per-pixel collision test
            # especially is not free. Then the branches.
            condition_leaf(node.cond, source: node.source) +
              (node.children + [node.else].compact).flat_map { |child| build(child) }
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
        # its per-pixel half is the expensive part; anything else reads as "test". The leaf
        # carries the line the test was written on, like any other statement's, so a frame
        # that is mostly tests can still be traced to the lines that do the testing.
        def condition_leaf(cond, source:)
          c = @pricing.expr_cost(cond)
          return [] unless c.positive?

          arithmetic = arithmetic_leaves(cond, category: :logic, source: source)
          own = c - sum(arithmetic)
          return arithmetic unless own.positive?

          collision = cond.walk.any? { |n| n.kind == :pixels_overlap }
          name = collision ? "collision test" : "test"
          arithmetic + [Entry.new(op: collision ? :collision : :cond, name: name, label: name, cost: own,
                                  source: source)]
        end

        # A drawing or compute op becomes a leaf, with the dear arithmetic it was handed
        # split out ahead of it — the arithmetic runs before the statement can, and reads
        # that way. Anything that costs nothing at all is dropped.
        def build_leaf(node)
          c = @pricing.op_cost(node)
          return [] unless c.positive?

          arithmetic = arithmetic_leaves(node, category: Tree.category_of(node.kind), source: node.source)
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
          [Entry.new(op: node.kind, label: @tree.label_of(node), cost: cost, source: node.source, **size)]
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

          if (kind = @pricing.arithmetic_kind(value))
            out << Entry.new(op: kind.op, name: kind.name, label: kind.name,
                             cost: @pricing.own_cost(value, true), category: category, source: source)
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
        # Tree#weigh_leaves). The case line SAYS so, once, since it is a fact about the
        # dispatch and not about any one scene: a reader sees a parent equal to one of its
        # children and would otherwise have to work out for themselves why.
        def build_case(node)
          branches = node.clauses.map do |value, target|
            kids = func_children(target)
            Entry.new(op: :branch, label: "#{value} -> :#{target}", cost: sum(kids), children: kids)
          end
          worst = branches.max_by(&:cost)
          Entry.new(op: :case, label: "case_var :#{node.var} (the dearest scene)", cost: worst&.cost || 0,
                    source: node.source,
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
          kids = loop_overhead_leaf(node, factor) +
                 within_loop(node) { node.children.flat_map { |child| build(child) } }
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
            @pricing.fast_memory_factor
        end

        def spill_cost(node)
          shape = loop_shape(node)
          return 0 unless shape&.spilled?

          shape.spills * @weights[:loop_spill]
        end

        def loop_start_cost(node)
          @weights[held_loop?(node) ? :loop_start_held : :loop_start] * @pricing.fast_memory_factor
        end

        # A timed trigger (every/after) as a labeled container: it carries its body's
        # full cost — the cost of the frame it does fire — so the tree and the
        # heaviest-frame figure read true. The label names the intent, e.g. "every 30".
        #
        # It also carries HOW OFTEN it fires, which is what stops the hottest list ranking
        # a frame nobody plays. `every 6` runs one frame in six, so its body is a sixth of
        # what an average frame pays; `after` fires once ever and pays nothing again. The
        # cost above stays whole (that is the frame it does fire, and the console still has
        # to survive it) and the factor says what to multiply it by for a normal frame —
        # the same discount #steady applies, said here so the tree can apply it too.
        def build_timer(node, label)
          kids = node.children.flat_map { |child| build(child) }
          Entry.new(op: node.kind, label: label, cost: sum(kids), source: node.source,
                    children: kids, factor: timer_share(node))
        end

        # One frame in +period+ for `every`; nothing at all for `after`, which fires once
        # and is a boot cost rather than a per-frame one.
        def timer_share(node)
          node.kind == :every ? Rational(1, node.period) : 0
        end

        def func_children(name)
          return [] if @stack.include?(name)
          func = @catalogue.funcs[name] or return []
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
          early = early_exit_passes(node, typical: typical)
          return early if early
          return frames_answered_for(typical: typical) if counts_frames?(count)
          return [count.value, "x#{count.value}"] if count.is_a?(Node) && count.kind == :int
          if count.is_a?(Node) && count.kind == :list_len && @catalogue.capacities[count.name]
            cap = @catalogue.capacities[count.name]
            return [cap, "x<=#{cap} (#{count.name} capacity)"] unless typical && !@at_full_capacity

            usual = list_length(count.name)
            return [usual, "x#{usual} (#{count.name} usually)"]
          end
          worked_out_passes(node, typical: typical)
        end

        # A LOOP COUNTED BY SOMETHING THE GAME WORKS OUT. Nothing in the program says how many
        # passes it makes and nothing bounds it, so unsaid it is charged nothing — which is not
        # a cautious guess but a hole, and the report says so where it lands.
        #
        # It is worth a hole rather than a guess because there is nothing to guess FROM: a
        # capacity or a ceiling can be shared out (a list gets a quarter of its capacity), and
        # here there is no number at all. What the author can say is `estimate: { usually: N,
        # most: M }`, and then this counts properly — which matters, because the loop that draws
        # everything standing in a room is this shape, and read as free it hid a game's largest
        # cost from the one report meant to find it.
        def worked_out_passes(node, typical:)
          usually = node.usually
          most = node.most
          return [usually || 0, "x#{usually} (usually, worked out)"] if typical && usually
          return [most, "x<=#{most} (at most, worked out)"] if !typical && most
          return [usually, "x#{usually} (usually, worked out — the most is not said)"] if usually

          [0, "x? (unbounded)"]
        end

        # THE ONE VARIABLE COUNT THAT IS NOT A GUESS. Every `once_a_frame` body is called from a
        # loop counted by how many frames the pass that just ended answered for — so its count
        # is a variable, and a variable count has no provable bound and is charged nothing.
        #
        # This one does have a bound, at both ends, and neither comes from reading the program.
        # A pass that keeps up is one frame, which is what every frame of a game that fits
        # costs; and a pass is held at a cap however late it runs, which is the most it can ever
        # cost. Left to the unbounded rule, moving work into a `once_a_frame` made a frame look
        # CHEAPER — the estimate is what an author decides by, and a screen shake, a fade, or a
        # whole game's movement would have been free in it.
        def counts_frames?(count)
          count.is_a?(Node) && count.kind == :var_ref && count.name == IR::Frames::STEP
        end

        def frames_answered_for(typical:)
          return [1, "x1 (a frame)"] if typical

          [IR::Frames::MOST, "x<=#{IR::Frames::MOST} (a pass this late is held here)"]
        end

        # Ask the every-frame question AS THOUGH EVERYTHING WERE FULL, for the length of a
        # block — a list holding its capacity, a pool with every slot live. One caller wants
        # that: the guardrail that says at what length a growing list stops fitting in a
        # frame (see Verdicts#budget_thresholds) is asking about the frames a game has not
        # reached yet, which is the one question a typical figure is the wrong answer to.
        def at_full_capacity
          was = @at_full_capacity
          @at_full_capacity = true
          yield
        ensure
          @at_full_capacity = was
        end

        # A LOOP THAT CAN STOP EARLY, which makes its count a ceiling rather than a number of
        # passes. Nothing in the program says where it really leaves, so this is the same
        # question a list's length is, from the other side: a known ceiling with an unknown
        # real count.
        #
        # It matters more here than anywhere else, because a ceiling is picked so it can never
        # be reached and this kind of loop sits inside another one. A ray that gives up after
        # forty-eight crossings meets a wall in a handful, and eighty rays multiply the
        # difference — counting the ceiling read seven times what the console really does.
        #
        # The WORST case still counts every pass, and the tree still prints the ceiling.
        def early_exit_passes(node, typical:)
          return nil unless stops_early?(node)

          ceiling = node.count.is_a?(Node) && node.count.kind == :int ? node.count.value : nil
          return [ceiling || 0, "x<=#{ceiling || '?'} (stops early)"] unless typical

          said = node.usually
          passes = said || (ceiling && unsaid_share(ceiling)) || 0
          [passes, "x#{passes} (usually, of #{ceiling || '?'})"]
        end

        # Whether this loop can leave before its count runs out. A stop_when of a plain nought
        # is what a loop with no early exit carries, so it is not one.
        def stops_early?(node)
          leave = node.stop_when
          !leave.nil? && !(leave.kind == :int && leave.value.zero?)
        end

        # HOW MUCH OF A CAPACITY IS USUALLY IN USE, when nothing in the program says.
        #
        # A QUARTER of it, for a list's length and for a pool's live slots alike, because a
        # capacity is picked as a ceiling the thing must never reach — and a list's is then
        # rounded up to a power of two on top of that — so it already sits above the biggest
        # number the author had in mind. A quarter is still real work: every pass of the walk
        # is counted whatever this says, and it is nearer the truth than the ceiling for
        # anything a game grows into.
        #
        # Guessing at all is a deliberate call. The alternative is to keep charging the
        # ceiling, and that is not the safe direction here: it is not a couple of
        # instructions over, it is a hundred times over on the one line that dominates the
        # frame, and an estimate that cries wolf on a game which fits teaches an author to
        # stop reading it. The worst case is still counted and still printed — see the tree,
        # which keeps the capacity, and the line the report prints beside the verdict.
        UNSAID_SHARE = 4

        # How long a list usually is, which nothing in a program says out loud. The author can
        # say it (`list :body, capacity: 256, estimate: { usually: 12 }`) and then this is
        # simply what they said; otherwise it is the guess above, and the report says so.
        def list_length(name)
          @catalogue.list_lengths[name] || unsaid_share(@catalogue.capacities[name])
        end
      end
    end
  end
end

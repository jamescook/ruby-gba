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
          analyze(program).sum { |node| node[:cost] }
        end

        # The whole per-frame cost that actually recurs *every* frame (drawing, logic,
        # and sound) — the 60fps load. Cost hints scale work down: an every(k) body
        # counts 1/k, a transition-guarded body counts 0, and so on. Untagged work
        # weighs 1, so a program with no hints has steady_cost == frame_cost. For the
        # tear risk (drawing only) use #steady_drawing_cost.
        def steady_cost(program)
          in_fast_frame { steady_statements(program).sum { |node| steady(node) } }
        end

        # The recurring drawing cost alone — the tear risk. Only drawing races the
        # brief vblank window; logic and sound run through the visible frame and can't
        # tear, so they're excluded here (they still count in #steady_cost's 60fps load).
        def steady_drawing_cost(program)
          in_fast_frame { steady_statements(program).sum { |node| steady(node, true) } }
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
        # `drawing_only` restricts the sum to drawing ops — the tear risk, since only
        # drawing competes with the brief vblank window. Logic and sound run through the
        # visible frame and can't tear, so they're excluded from the tear measure (but
        # counted in the whole-frame 60fps measure). Default false = the full load.
        # +worst+ runs the same walk asking for everything a frame could cost rather than
        # what it usually does — see #expr_cost. Differencing the two is how the estimate
        # names what the recurring load leaves out.
        def steady(node, drawing_only = false, worst: false)
          selectivity(node) * raw_steady(node, drawing_only, worst)
        end

        def raw_steady(node, drawing_only, worst)
          case node.kind
          when :program, :loop, :else then node.children.sum { |child| steady(child, drawing_only, worst: worst) }
          # The condition is tested every frame, whichever way it goes — that's where a
          # collision test's comparison chain lives — so it's priced here; only the branch
          # bodies are scaled by how often they run. (Its cost is logic, so the
          # drawing-only measure skips it.)
          when :if
            cond = drawing_only ? 0 : expr_cost(node[:cond], worst: worst)
            cond + node.children.sum { |child| steady(child, drawing_only, worst: worst) } +
              (node[:else] ? steady(node[:else], drawing_only, worst: worst) : 0)
          # A pass round a loop costs something before the body does anything — see
          # #loop_pass_leaf. It is bookkeeping, so the tear measure (drawing only) skips it.
          when :repeat
            body = node.children.sum { |child| steady(child, drawing_only, worst: worst) }
            repeat_factor(node).first * (body + (drawing_only ? 0 : loop_pass_cost))
          # A timed trigger's steady per-frame cost follows from its kind: every(k)
          # runs one frame in k, so its body counts 1/k; after(n) fires once ever, so
          # it adds nothing to the every-frame load.
          when :every
            Rational(1, node[:period]) * node.children.sum { |child| steady(child, drawing_only, worst: worst) }
          when :after then 0
          when :case then node[:clauses].map { |_value, target| steady_func(target, drawing_only, worst: worst) }.max || 0
          when :call then steady_func(node[:target], drawing_only, worst: worst)
          when :func then 0
          else drawing_only && category_of(node.kind) != :drawing ? 0 : op_cost(node, worst: worst)
          end
        end

        def steady_func(name, drawing_only = false, worst: false)
          return 0 if @stack.include?(name)
          func = @funcs[name] or return 0
          @stack.push(name)
          total = in_fast_memory(name) { func.children.sum { |child| steady(child, drawing_only, worst: worst) } }
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

          case node[:cond]&.kind
          when :pressed then 0
          when :chance then Rational(node[:cond][:percent], 100)
          else 1
          end
        end

        # What every per-pixel collision test in a frame costs if they all land at once —
        # the part of the worst case the recurring load leaves out, so the estimate can say
        # so out loud rather than just showing a bigger number further down.
        def collision_worst_case(program)
          statements = steady_statements(program)
          everything = statements.sum { |node| steady(node, false, worst: true) }
          everything - statements.sum { |node| steady(node, false) }
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
          @songs = {}
          @bitmaps = {}
          @backing = {}
          @objects = {}
          program.walk do |node|
            @funcs[node[:name]] = node if node.kind == :func
            @capacities[node[:name]] = node[:capacity] if node.kind == :list_new
            @songs[node[:name]] = node if node.kind == :song
            @bitmaps[node[:name]] = catalogue_bitmap(node) if node.kind == :bitmap
            @objects[node[:name]] = catalogue_object(node) if node.kind == :object
            @backing[node[:name]] = [node[:width], node[:height]] if node.kind == :backing_buffer
          end
        end

        # What drawing one sprite costs, in the two ways a sprite can be more than a
        # position: it can be turned to an angle, and it can be drawn at a size. Both are
        # settled on the declaration — a sprite that never turns keeps a fixed angle
        # there — so they are read once here rather than at every frame's draw.
        def catalogue_object(node)
          turns = !constant_operand?(node[:angle], 0)
          Sprite.new(turns: turns || resizes?(node), resizes: resizes?(node))
        end

        def resizes?(node) = !constant_operand?(node[:scale], Build::SCALE_ONE)

        def constant_operand?(node, value)
          node.kind == :int && node[:value] == value
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
          see_through = node[:transparent]
          width = node[:width]
          height = node[:height]
          unless see_through
            return Bitmap.new(width: width, height: height, transparent: false,
                              lit_pixels: width * height, wide_color_pixels: 0, lit_rows: height)
          end

          # The pixels arrive as a run of 16-bit colors, row after row.
          rows = node[:pixels].unpack("v*").each_slice(width).map { |row| row.reject { |px| px == see_through } }
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
            condition_leaf(node[:cond]) + (node.children + [node[:else]].compact).flat_map { |child| build(child) }
          when :else then node.children.flat_map { |child| build(child) }
          when :case then [build_case(node)]
          when :call then [build_call(node)]
          when :repeat then [build_repeat(node)]
          when :every then [build_timer(node, "every #{node[:period]}")]
          when :after then [build_timer(node, "after #{node[:frames]}")]
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
          arithmetic + [{ op: collision ? :collision : :cond, name: name, label: name, cost: own, children: [] }]
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

          [{ op: node.kind, label: label_of(node), cost: cost, w: node[:w], h: node[:h],
             source: node.source, children: [] }]
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
            out << { op: kind.op, name: kind.name, label: kind.name, cost: own_cost(value, true),
                     category: category, source: source, children: [] }
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
          branches = node[:clauses].map do |value, target|
            kids = func_children(target)
            { op: :branch, label: "#{value} -> :#{target}", cost: sum(kids), children: kids }
          end
          worst = branches.max_by { |b| b[:cost] }
          { op: :case, label: "case_var :#{node[:var]}", cost: worst ? worst[:cost] : 0, source: node.source,
            children: branches.map { |b| b.merge(factor: b.equal?(worst) ? 1 : 0) } }
        end

        # A call is its target func's body, inlined (guarding against a call cycle).
        def build_call(node)
          kids = func_children(node[:target])
          { op: :call, label: "call :#{node[:target]}", cost: sum(kids), source: node.source, children: kids }
        end

        # A repeat runs its body count times, so its cost multiplies — and so does the
        # cost of going round, which leads the body because that is when it happens.
        def build_repeat(node)
          factor, note = repeat_factor(node)
          kids = loop_pass_leaf + node.children.flat_map { |child| build(child) }
          { op: :repeat, label: "repeat #{note}", cost: factor * sum(kids), factor: factor,
            source: node.source, children: kids }
        end

        # What one pass round a loop costs before the body does anything: counting, testing
        # the count, and jumping back. Small — about three plain steps — but it is paid
        # once per pass like everything else in the body, so a loop that runs six hundred
        # times pays it six hundred times. Shown as its own line so a reader can see that a
        # loop is never free, and that a tight loop over a cheap body is mostly loop.
        def loop_pass_leaf
          [{ op: :loop_pass, name: "the loop itself", label: "the loop itself",
             cost: loop_pass_cost, children: [] }]
        end

        # Going round a loop is instructions like any other, so it is charged less where
        # the code runs faster.
        def loop_pass_cost = @weights[:loop_pass] * fast_memory_factor

        # A timed trigger (every/after) as a labeled container: it carries its body's
        # full cost — the cost of the frame it does fire — so the tree and the
        # heaviest-frame figure read true; the steady discount is applied separately
        # (see #raw_steady). The label names the intent, e.g. "every 30".
        def build_timer(node, label)
          kids = node.children.flat_map { |child| build(child) }
          { op: node.kind, label: label, cost: sum(kids), source: node.source, children: kids }
        end

        def func_children(name)
          return [] if @stack.include?(name)
          func = @funcs[name] or return []
          @stack.push(name)
          kids = in_fast_memory(name) { func.children.flat_map { |child| build(child) } }
          @stack.pop
          kids
        end

        def sum(nodes) = nodes.sum { |node| node[:cost] }

        # How many times a repeat runs, and a human note: a literal count exactly; a
        # list's length up to its capacity (the most it can hold). An unknown count
        # (a plain variable) has no provable bound, so it contributes zero to the
        # estimate and is noted as unbounded rather than guessed.
        def repeat_factor(node)
          count = node[:count]
          return [count[:value], "x#{count[:value]}"] if count.is_a?(Node) && count.kind == :int
          if count.is_a?(Node) && count.kind == :list_len && @capacities[count[:name]]
            cap = @capacities[count[:name]]
            return [cap, "x<=#{cap} (#{count[:name]} capacity)"]
          end
          [0, "x? (unbounded)"]
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "reductions"
require_relative "domain"
require_relative "benchmarks"

module RubyGBA
  module Calibration
    # Every weight in the cost model, and the recipe that measures it.
    #
    # Each recipe is the same three steps: build ROMs that differ only in how much of one
    # thing they do, read what they cost on the emulator, and reduce the readings to a rate.
    # The benchmarks do the building, {Reductions} does the arithmetic, and this class holds
    # the recipes — so what is left here reads as a list of decisions rather than a script.
    #
    # It also records a {Domain} per weight: what was varied, and between which two counts.
    # That is the honest answer to "where can this number be trusted", and it can only be
    # written here, beside the measurement, or it drifts.
    #
    # ORDER MATTERS. The weights come out in the order they are assigned, and that is the
    # order they appear in the generated fixture — so a re-run produces a diff of numbers,
    # not a reshuffle.
    class Calibrator
      attr_reader :weights, :domains

      def initialize(measurer)
        @bench = Benchmarks.new(measurer)
        @weights = {}
        @domains = {}
      end

      # Run every benchmark and answer self, with #weights and #domains filled in.
      def run
        frame
        logic
        per_pixel_drawing
        live_digit
        sound
        dma
        tiled_upkeep
        interrupts
        affine_sprites
        display_registers
        saving
        tearfree_screen
        collision
        fast_memory
        self
      end

      private

      # Record a weight and where it was measured. +varies+ names the program-visible quantity
      # the measurement swept, if there is one; leaving it out says this weight has no
      # countable regime (an add costs what an add costs) and so is never warned about.
      def weigh(name, value, varies: nil, from: nil, to: nil, note: nil)
        @weights[name] = value
        @domains[name] = Domain.new(varies: varies, from: from, to: to, note: note)
        value
      end

      # --- the frame itself ---

      # What a frame costs before the game does anything: the BIOS sleeping the console until
      # the display's interrupt, the console's own entry to and exit from the handler that
      # counts the frame, and the dozen instructions that turn that count into how many frames
      # the last pass really took. Nobody writes any of it and every frame pays it.
      #
      # MEASURED ON ITS OWN, because a marginal rate cannot see it. Differencing two programs
      # cancels whatever both pay once, and that is exactly this — so the technique every other
      # weight in this file uses is built to remove the one cost every program shares.
      #
      # AS THE BASE OF A LINE rather than an empty loop's reading: two ordinary programs of
      # plain statements, and where the line through them meets no statements at all. An empty
      # loop is a program a build is free to treat specially; these two are not. The slope the
      # same pair gives is op_step, which is the measurement checking itself against a weight
      # arrived at another way.
      #
      # ONE WEIGHT AND NOT TWO, unlike the interrupt weights below. Nearly all of this is the
      # console's own doing and runs where the console keeps it however fast our memory is;
      # only the dozen instructions that count the frame are ours. So it is priced as a cost
      # the quick memory cannot reach — Pricing::CONSOLES_OWN_TIME, the same treatment a
      # transfer engine's stall gets.
      #
      # The two frames are far enough apart to fit a line through and both far enough under a
      # frame's 228 scanlines that neither reading is anywhere near the ceiling.
      FRAME_LO = 20
      FRAME_HI = 120

      def frame
        _slope, base = Reductions.fit(FRAME_LO, @bench.plain_frame_busy(FRAME_LO),
                                      FRAME_HI, @bench.plain_frame_busy(FRAME_HI))
        weigh(:frame_overhead, base,
              note: "waiting for the screen and counting the frame, which every frame pays")
      end

      # --- logic (the op_* tiers) ---

      def logic
        # THE FOUR SHAPES OF PLAIN WORK, each measured on its own because in instructions they
        # are four prices and not one:
        #
        #   add :y, 1        8   a statement that reads a variable, changes it, writes it back
        #   set :y, x        6   a statement that only writes one — three quarters of the above
        #   x + 2            4   an operator: hold the left side, work out the right, combine
        #   x > 2            8+  a comparison, which also turns the answer into a 1 or a 0
        #
        # One figure for all four would be about six, which reads an `add` a quarter light, a
        # plain operator half again too dear and a comparison a third light — on the commonest
        # things a program does.
        #
        # WHICH VARIABLE a statement weight is measured on is part of the recipe, not a detail:
        # see Benchmarks#stable_busy for why the harness keeps a spare in the first slot. On the
        # program's first variable an `add` measures six rather than eight, and exactly one
        # variable per program is like that.
        weigh(:op_step, @bench.per_op("step", 500, 2, 8) { |b, _xv| b.add :y, 1 },
              note: "a statement that reads a variable, changes it and writes it back")
        # An assignment, MINUS the variable it was handed: `set :y, x` reads one, and the model
        # charges a read where it finds it (see #operand_read). Left in, this weight would pay
        # for the first variable a statement reads and nothing for the second, which is what
        # made `n.set(m + p)` — two reads, one paid for — run two instructions dearer than the
        # model said.
        weigh(:op_assign, @bench.per_op("assign", 500, 2, 8) { |b, xv| b.set :y, xv } - operand_read,
              note: "a statement that only writes a variable, with the value already worked out")
        weigh(:op_plain, @bench.per_operator("plain") { |b, xv| b.set :y, (xv + 2) },
              note: "a plain operator — add, subtract, and the and/or that combine conditions")
        weigh(:op_compare,
              @bench.per_compare_operator("cmp") do
                IR::Build.binop(:>, IR::Build.var_ref(:d), IR::Build.int(200))
              end,
              note: "a comparison, priced on the answer that costs more (false, which jumps)")

        # THE TWO THINGS THAT RIDE ON TOP OF ANY OF THE FOUR. Both are about a variable, and
        # they answer different questions: this one is what READING one costs, and the next is
        # what reaching a FAR one costs on top of that.
        #
        # A statement or an operator has to get its operands from somewhere, and where the
        # weight above got its own is part of the weight. `set :y, x` reads a variable where a
        # plain operator's benchmark is handed the NUMBER 2. So this is the difference between
        # those two operands and nothing else: the same statement, the same operator, a
        # variable in place of the number.
        #
        # IT MEASURES NOUGHT NOW, and that is the answer rather than a failed measurement. A
        # read used to name the base of the variable memory and then load from it, so a second
        # variable operand was two instructions against the number's one. The base is already
        # in the register from the operand before it, so the second read is a bare load — one
        # instruction, the same as the number it stands in for. Both fixtures emit the same
        # instructions in the same order and differ in that one.
        weigh(:var_operand, operand_read,
              note: "reading a variable handed to a statement or an operator, over the number a weight assumes")

        # There is no weight here for where a variable SITS, and there used to be. A read once
        # built the variable's whole address and then loaded from it, and the address cost one
        # instruction for the first variable, two for the next sixty-three and three past that —
        # so in a game with a list or a pool, whose 256 bytes are claimed before any variable
        # gets a home, nearly every variable was the dear kind. A read now names the base of the
        # variable memory, which is a number this console can hold in one instruction, and
        # carries the distance inside the load. The hundredth variable costs what the first does,
        # so the four above are measured on any variable at all and there is nothing left over.

        # A LOOP COSTS TWO THINGS, and they are measured apart because they scale apart: a
        # rate per pass, and a fixed cost for being entered at all.
        #
        # The pass first. Every weight around it is measured with the trip count held FIXED,
        # which cancels it — so it needs a case of its own or it is never measured. Two trip
        # counts differenced leave the counter, the compare and the branch back.
        #
        # Differencing trip counts also cancels the ENTERING, which is why that needs the
        # second case below and why this one has no regime to be warned about: with the fixed
        # part measured on its own, what is left here is a true rate, and it holds from one
        # pass to hundreds.
        # And it is measured TWICE, because a loop comes in two shapes and a program gets
        # whichever its body allows: the counter and the limit stay in registers unless
        # something in the body could land on them, and then both live in memory and every
        # pass loads and stores them (Backends::GBA::LoopForm decides).
        weigh(:loop_pass,
              Reductions.marginal(@bench.loop_busy(900, blocked: true),
                                  @bench.loop_busy(300, blocked: true), over: 600),
              note: "one pass of a repeat whose counter lives in memory")
        weigh(:loop_pass_held,
              Reductions.marginal(@bench.loop_busy(900), @bench.loop_busy(300), over: 600),
              note: "one pass of a repeat whose counter stays in a register")

        # ...and what SAVING the pair around one statement costs, which is what lets a loop keep
        # the fast shape while its body calls a routine. Both ROMs hold the same call, so its
        # cost cancels between them and what is left is the two pass weights — the bracket is
        # the difference between them, less the difference the two shapes already have.
        #
        # Measured, one bracket is worth about two fifths of what a pass through memory costs
        # over a pass in registers. So one bracket is a clear saving, two is a small one, and
        # three would cost more than it saved — which is where LoopForm::SPILL_LIMIT is set.
        weigh(:loop_spill,
              Reductions.marginal(@bench.loop_spill_busy(900), @bench.loop_spill_busy(300), over: 600) -
              Reductions.marginal(@bench.loop_spill_busy(900, blocked: true),
                                  @bench.loop_spill_busy(300, blocked: true), over: 600) +
              @weights[:loop_pass] - @weights[:loop_pass_held],
              note: "saving and putting back a loop's registers around one statement")

        # ...and the entering, in both shapes too: working the trip count out into the loop's
        # limit, zeroing its counter, and the branch that leaves. Measured over how many LOOPS
        # a frame holds rather than how long one is, which is the only way to see it, then with
        # the passes those loops do taken back out.
        #
        # Through memory it is worth about twenty ordinary instructions, so a loop of four
        # passes spends a fifth of itself simply being entered — and a game reaches for a short
        # loop often (a handful of rows, a few slots, a per-tick step).
        weigh(:loop_start,
              Reductions.residual(
                Reductions.marginal(@bench.loop_start_busy(12, blocked: true),
                                    @bench.loop_start_busy(4, blocked: true), over: 8),
                Benchmarks::LOOP_START_PASSES * @weights[:loop_pass]
              ),
              note: "entering a repeat whose counter lives in memory")
        weigh(:loop_start_held,
              Reductions.residual(
                Reductions.marginal(@bench.loop_start_busy(12), @bench.loop_start_busy(4), over: 8),
                Benchmarks::LOOP_START_PASSES * @weights[:loop_pass_held]
              ),
              note: "entering a repeat whose counter stays in a register")

        # op_mul / op_div = op_plain + the operator's extra cost over an add (a `set :y,
        # (x <op> 100)` is a set plus the operator; differencing against `+` isolates it).
        # A PLAIN OPERATOR is the thing being added to, not a whole statement: these weights
        # are charged beside the statement that holds them, so building one out of a statement
        # charged the statement twice.
        #
        # WHICH OPERAND EACH ONE USES IS THE WHOLE POINT, because the lowering reduces some of
        # them and a weight measured on a reduced op would price every op at the reduced cost —
        # the model would then tell an author that dividing by 100 is free.
        #
        #   * 100         a real multiply. By a power of two it would be a shift.
        #   / d           a real divide, and the ONLY kind left: a divisor written into the
        #                 program is turned into a multiply at build time, so a divisor the
        #                 game works out is now the only one that reaches the BIOS routine.
        #   / 100         that reduction — a multiply by a reciprocal, its own tier.
        #
        weigh(:op_mul,
              @weights[:op_plain] +
              over_an_add(tag: "mul", against: "addm", passes: 300, lo: 2, hi: 6) { |b, xv| b.set :y, (xv * 100) },
              note: "a multiply by a number written in the program")

        # THE POWER-OF-TWO CASES, which the lowering reduces to a shift or a mask. Measured,
        # they are the cheapest operators there are — and they are three prices, not one:
        #
        #   * 8     one instruction. The shift, and nothing else.
        #   % 64    one. Keeping the low bits IS the answer, sign and all, so it is a mask.
        #   / 8     three. A shift rounds DOWN and `/` rounds toward zero, so a negative
        #           numerator is nudged up first — see emit_divide_by_power_of_two.
        #
        # A plain step for any of them would read `set :y, (x * 8)` at twice what it costs.
        # These are the operator's OWN cost, not a statement over again (see
        # Benchmarks#per_operator), which is what makes them compose with the statement they
        # sit in instead of doubling it.
        #
        # The wrap is measured at 64, which is the size a game actually wraps onto — an angle,
        # a sine table's index. A mask too big to ride inside the instruction has to be loaded
        # first, so wrapping onto 512 or more costs about two instructions more than this.
        weigh(:op_mul_pow2, @bench.per_operator("mulp") { |b, xv| b.set :y, (xv * 8) },
              note: "multiplying by a power of two written in the program — a shift")
        weigh(:op_mod_pow2, @bench.per_operator("modp") { |b, xv| b.set :y, (xv % 64) },
              note: "wrapping onto a power of two written in the program — a mask, measured at 64")
        weigh(:op_div_pow2, @bench.per_operator("divp") { |b, xv| b.set :y, (xv / 8) },
              note: "dividing by a power of two written in the program — a shift, and the rounding it needs")

        # Reading one element out of a list or a table. Both were priced at NOTHING — "a read
        # like t[i] is a single load" — and neither is a single load. A list element sits in a
        # ring, so reaching it means the head, the wrap, the scale to bytes and the base before
        # anything is loaded; a table read makes the index safe first. Measured, a list read is
        # thirteen instructions and a table read is thirteen or twenty-three.
        #
        # It is the WHOLE read, not the extra over reading a plain variable, because nothing
        # above pays for reading an operand either (see Benchmarks#indexed_read_busy).
        #
        # A table is TWO of them. Its length decides how an out-of-range index is made safe —
        # a power-of-two table wraps it with one mask, any other size clamps it to the ends
        # with a compare and a branch per bound — so the cheap one must not be charged for
        # both. Most tables a game writes by hand (a sine table of 360, a level of 60) are the
        # dearer kind.
        #
        # THE INDEX COMES BACK OUT of each. The reading and its baseline both store into the
        # same variable, so that end cancels — what does not is the INDEX, which the read has
        # and the baseline does not. The model charges an index where it finds it, so it comes
        # out here rather than being paid for twice.
        index = operand_read
        weigh(:list_read, @bench.per_indexed_read(:list) - index,
              note: "reading one element of a list, apart from the index")
        # ...and ONE element read per pass of a walk, by the loop's own counter, on a plain
        # list — the shape every pool's live test and every list `each` emits. Measured as a
        # walk against the same walk testing a variable (see Benchmarks#per_walk_read), because
        # the read above is measured over several reads inside one pass, and that regime is
        # cheaper per element than a walk ever sees; priced at it, a pool's whole walk read a
        # third over the console. Nothing to hand back: the walk's index is its counter.
        weigh(:list_read_in_walk, @bench.per_walk_read,
              note: "reading one element of a plain list per pass of a walk, by a counter kept in a register (a pool's live test, a list's each)")
        # ...and the same walk with its counter in memory — a body that holds a loop of its
        # own, or drops to raw instructions — where the counter is loaded before the element
        # is reached.
        weigh(:list_read_in_walk_memory, @bench.per_walk_read(blocked: true),
              note: "the same, by a counter that lives in memory")
        # ...and WRITING one, which was charged as a plain variable statement until the two
        # stopped costing alike. A variable is reached from a base held in a register plus a
        # distance settled while building; an element has its index worked out and added, which
        # no base can shorten. Measured against writing a variable the same number of times, so
        # what is left is the indexing.
        weigh(:list_write, @weights[:op_assign] + @bench.per_indexed_write,
              note: "writing one element of a list, apart from the value")
        weigh(:table_read, @bench.per_indexed_read(:table) - index,
              note: "reading one element of a table whose length is a power of two (the index wraps)")
        weigh(:table_read_clamped, @bench.per_indexed_read(:table_clamped) - index,
              note: "reading one element of a table of any other length (the index clamps)")

        # A divisor the game works out is the one case that still walks the answer a bit at a
        # time, so it is TWO numbers: a fixed setup, and a step for every bit of the answer. The
        # base is measured at an answer of no width at all, which is what op_div has always been
        # (7 / 100 answers zero), so this number carries on from the one before it.
        #
        # ONE OPERAND COMES BACK OUT: the divide is measured on `set :out, (n / d)`, whose
        # divisor is a variable where the add it is differenced against holds a number.
        addd = @bench.per_op("addd", 60, 2, 6) { |b, xv| b.set :y, (xv + 2) }
        weigh(:op_div, @weights[:op_plain] + (@bench.per_divide(0) - addd) - operand_read,
              note: "starting a divide by a divisor the game works out, at an answer of no width")
        weigh(:op_div_bit, Reductions.marginal(@bench.per_divide(30), @bench.per_divide(0), over: 30),
              varies: :answer_bits, from: 0, to: 30,
              note: "one bit of the answer of such a divide")

        # A divide by a number written into the program: no call, just a 64-bit multiply by a
        # reciprocal worked out at build time and a couple of instructions to round it. A wrap
        # (`%`) by such a number is built on this and costs somewhat more, and is priced here
        # too — the same lumping of `/` and `%` the general tier already makes.
        weigh(:op_div_const,
              @weights[:op_plain] +
              over_an_add(tag: "divc", against: "addc", passes: 300, lo: 2, hi: 6) { |b, xv| b.set :y, (xv / 100) },
              note: "a divide by a number written in the program")

        # A fraction multiply is SMULL plus two instructions to shift the 64-bit product back
        # down — dearer than a plain multiply, nowhere near a divide. Same differencing.
        weigh(:op_mul_fix,
              @weights[:op_plain] +
              over_an_add(tag: "mulfix", against: "addf", passes: 300, lo: 2, hi: 6) do |b, xv|
                b.set :y, xv.times_fraction(2, fraction_bits: 16)
              end,
              note: "multiplying two numbers that hold a fraction")

        # Dividing one number holding a fraction by another. The numerator no longer fits a
        # register once it is widened, so this walks the whole width of the answer at a fixed
        # price — the dearest arithmetic there is. Both operands are worked out by the game;
        # with a numerator written down it folds into an ordinary division and is priced as one.
        #
        # ONE OPERAND COMES BACK OUT, for the reason the run-time divide's does: both its
        # operands are variables where the add it is differenced against holds a number.
        weigh(:op_div_fix,
              @weights[:op_plain] - operand_read +
              over_an_add(tag: "divfix", against: "addx", passes: 60, lo: 2, hi: 4) do |b, _xv, _dv, fv, gv|
                b.set :fout, (fv / gv)
              end,
              note: "dividing two numbers that hold a fraction")
      end

      # An operator's cost over a plain add, measured at the same shape of statement and the
      # same counts — which is what isolates the operator from the `set` wrapped round it.
      def over_an_add(tag:, against:, passes:, lo:, hi:, &op)
        @bench.per_op(tag, passes, lo, hi, &op) -
          @bench.per_op(against, passes, lo, hi) { |b, xv| b.set :y, (xv + 2) }
      end

      # WHAT READING A VARIABLE OPERAND COSTS, measured once and then TAKEN BACK OUT of every
      # weight whose benchmark read one. That subtraction is the other half of charging the
      # read where it happens (Pricing#own_cost prices a var_ref), and without it a program
      # would pay twice for the same read wherever the benchmark had one — a rectangle drawn
      # at a worked-out position, a blitted sprite, a live digit, every assignment.
      #
      # Every weight that absorbed one says so where it is measured, and how many. Nearly all
      # absorbed none: a weight found by differencing two ROMs that both read the same operands
      # has them cancel by construction, which is most of them.
      #
      # `set :y, (x + d)` against `set :y, (x + 2)`: the same statement, the same operator,
      # only the right-hand operand differs — a variable where the weights assume a number.
      def operand_read
        @operand_read ||=
          over_an_add(tag: "varop", against: "addv", passes: 300, lo: 2, hi: 6) do |b, xv, dv|
            b.set :y, (xv + dv)
          end
      end

      # --- per-pixel drawing ---
      #
      # A pixel comes in THREE shapes on the direct-color screen and they are not one price.

      def per_pixel_drawing
        # plot_pixel is a pixel drawn ON ITS OWN: it works out a whole address and loads its
        # color. Neither of the two below is that, and one of them is not close.
        weigh(:plot_pixel, @bench.per_op("plot", 150, 4, 8) { |b, _xv| b.pixel 10, 10, :red },
              note: "a pixel drawn on its own")

        # A pixel of a RUN of them, which is how a rectangle of a fixed size is drawn: the color
        # is already held and each pixel is one address and one store. A font glyph's lit pixel
        # is the same shape — it measures the same at every height on the screen — so ONE weight
        # covers both.
        run_mid = run_pixel_rate(Benchmarks::FILL_Y)
        weigh(:plot_run_pixel, run_mid, varies: :run_width, from: 4, to: 32,
                                       note: "a pixel of a fixed-size run, halfway down the screen")

        # The write itself costs the same wherever it lands. What differs is building the
        # ADDRESS, and a bigger number takes another step to build — so a row far enough down
        # the screen that its distance into the picture no longer fits in sixteen bits costs a
        # step more, on every pixel. That is the bottom twenty rows: a status bar, a floor.
        weigh(:plot_run_address_step, run_pixel_rate(Benchmarks::DEEP_Y) - run_mid,
              varies: :run_width, from: 4, to: 32,
              note: "the extra per pixel below the row where an address needs another byte")

        # A lit pixel of a TRANSPARENT image — what a software sprite is made of. The position
        # is worked out as the program runs, so every pixel is tested against the screen edges
        # on its own before it is written, and it costs over twice what a pixel of a fixed-size
        # rectangle does. Measured in red, a color that rides inside the instruction that writes
        # it (see blit_wide_color for the ones that do not).
        blit_4x8 = @bench.blit_busy(4, 8, 2)
        weigh(:blit_pixel, blit_pixel_rate(:red, blit_4x8),
              varies: :lit_pixels_per_row, from: 4, to: 32,
              note: "a lit pixel of a see-through image drawn at a worked-out position")

        # The extra for a pixel whose color does NOT fit inside that instruction, and so has to
        # be built in a step of its own first. Drawing a pixel at a time means writing the color
        # into every store, so this rides on every pixel of the art and is worth about a tenth
        # of one: two pictures of the same shape can differ by that much on their colors alone.
        # White is one of the colors that does not fit; red, green and blue all do.
        weigh(:blit_wide_color,
              blit_pixel_rate(:white, @bench.blit_busy(4, 8, 2, color: :white)) - @weights[:blit_pixel],
              varies: :lit_pixels_per_row, from: 4, to: 32,
              note: "the extra per pixel for a color that does not fit inside the write")

        # What one ROW of that costs beyond its own pixels: the row is tested against the top
        # and the bottom of the screen once, and its place in the picture worked out. A row with
        # nothing lit in it is skipped whole, so only lit rows pay this.
        weigh(:blit_row,
              Reductions.residual(Reductions.marginal(@bench.blit_busy(4, 32, 2), blit_4x8, over: (32 - 8) * 2),
                                  4 * @weights[:blit_pixel]),
              varies: :lit_rows, from: 8, to: 32,
              note: "one lit row of such an image, beyond its own pixels")

        # What a blit costs BEFORE its first row: where it goes is worked out once, whatever it
        # then draws. More COPIES of the same image at the same trip count gives the whole cost
        # of one blit; taking off the rows and pixels priced above leaves the part that is fixed.
        #
        # TWO OPERANDS COME BACK OUT — the x and the y, which every blit reads and which the
        # weights above cannot absorb, since they are differenced at a fixed copy count and so
        # cancel a position rather than paying for one.
        weigh(:blit_start,
              Reductions.residual(
                Reductions.marginal(@bench.blit_busy(4, 8, 2, copies: 3), blit_4x8, over: (3 - 1) * 2),
                8 * @weights[:blit_row], 4 * 8 * @weights[:blit_pixel], 2 * operand_read
              ),
              note: "what one such image costs before its first row, apart from reaching its position")

        column_rows
      end

      # ONE ROW OF A STRETCHED COLUMN, read on both screens because they write a pixel
      # differently and the answer decides which screen a first-person view should use.
      #
      # The tear-free screen has to read the pair a pixel shares, splice its own half and write
      # it back, where the direct-color screen just stores. It is still the cheaper of the two,
      # because a column has ONE x for its whole height — so the screen edges are tested once
      # instead of at every pixel, and the address walks down by a fixed step instead of being
      # worked out again. The three instructions the splice costs are less than the nine that
      # buys back.
      def column_rows
        one = @bench.column_row_cost("colr", tear_free: false)
        one_tf = @bench.column_row_cost("tfcolr", tear_free: true)
        weigh(:column_row, one,
              varies: :column_height, from: Benchmarks::COLUMN_SHORT, to: Benchmarks::COLUMN_TALL,
              note: "one row of a picture's column stretched to a height the game works out")
        weigh(:tearfree_column_row, one_tf,
              varies: :column_height, from: Benchmarks::COLUMN_SHORT, to: Benchmarks::COLUMN_TALL,
              note: "the same, on the tear-free screen")

        # WHAT A PIXEL BESIDE THE FIRST COSTS. A strip is ONE walk down the screen whatever
        # its width — the picture is read once and the screen row found once — so the pixels
        # beside the first are only their own writes. Reading it rather than assuming it is
        # what keeps the estimate honest about a view that draws wide strips.
        extra = Benchmarks::COLUMN_STRIP - 1
        weigh(:column_extra_pixel,
              Reductions.residual(@bench.column_row_cost("colw", tear_free: false, width: Benchmarks::COLUMN_STRIP),
                                  one) / extra,
              varies: :column_height, from: Benchmarks::COLUMN_SHORT, to: Benchmarks::COLUMN_TALL,
              note: "one more pixel across a stretched strip, beside the first")
        weigh(:tearfree_column_extra_pixel,
              Reductions.residual(@bench.column_row_cost("tfcolw", tear_free: true, width: Benchmarks::COLUMN_STRIP),
                                  one_tf) / extra,
              varies: :column_height, from: Benchmarks::COLUMN_SHORT, to: Benchmarks::COLUMN_TALL,
              note: "the same, on the tear-free screen")
      end

      def run_pixel_rate(y)
        Reductions.marginal(@bench.fill_rect_busy(32, 10, 20, y), @bench.fill_rect_busy(4, 10, 20, y),
                            over: (32 - 4) * 10 * 20)
      end

      def blit_pixel_rate(color, narrow)
        Reductions.marginal(@bench.blit_busy(32, 8, 2, color: color), narrow, over: (32 - 4) * 8 * 2)
      end

      # --- a LIVE digit: the walk over the chosen glyph, not the pixels it lights ---
      #
      # A line of text has its pixels settled while building. A live digit cannot: which of the
      # ten shows is only known as the game runs, so the console walks the chosen glyph out of a
      # table — testing EVERY cell of the digit's box, lit or not, and stamping each lit one.
      #
      # Three things cost, and three measurements separate them: two DIGITS of one font differ
      # only in how many cells are lit, and two FONTS at the same digit differ in the size of
      # the box as well.
      def live_digit
        default = Fonts.get(:default)
        tiny = Fonts.get(:tiny)
        lit_spread = (default.text_pixels("8") - default.text_pixels("1")).to_f
        d8 = @bench.per_digit_node(8, :default)
        d1 = @bench.per_digit_node(1, :default)
        t8 = @bench.per_digit_node(8, :tiny)
        box_spread = (Benchmarks.font_box(default) - Benchmarks.font_box(tiny)).to_f

        weigh(:digit_pixel, (d8 - d1) / lit_spread,
              note: "stamping one lit cell of a live digit")
        weigh(:digit_cell,
              ((d8 - t8) - ((default.text_pixels("8") - tiny.text_pixels("8")) * @weights[:digit_pixel])) /
              box_spread,
              note: "testing one cell of a live digit's box, lit or not")
        # Whatever is left once the box and the lit cells are paid for is what starting one
        # costs: finding the chosen glyph in the table before any of it is walked. (The walk's
        # per-ROW work rides inside the per-cell figure — two fonts cannot separate a row from a
        # cell, and fitted across both built-in fonts it lands within a hundredth on each.)
        #
        # ONE OPERAND COMES BACK OUT: a live digit reads the number it shows, and every reading
        # here does, so it would otherwise be paid for twice.
        weigh(:digit_start,
              Reductions.residual(d8, Benchmarks.font_box(default) * @weights[:digit_cell],
                                  default.text_pixels("8") * @weights[:digit_pixel], operand_read),
              note: "finding the chosen glyph before the walk starts, apart from reading the number")
        # Stamping a lit cell on the TEAR-FREE screen, where a pixel is one byte sharing its
        # sixteen bits with its neighbour and so is read, half changed and written back. The
        # WALK is the same loop on both screens — measured, its start and its per-cell cost come
        # out the same to within a hundredth — so this is the only part that moves.
        weigh(:tearfree_digit_pixel,
              (@bench.per_digit_node(8, :default, tear_free: true) -
               @bench.per_digit_node(1, :default, tear_free: true)) / lit_spread,
              note: "the same, on the tear-free screen")
      end

      # --- sound ---

      def sound
        weigh(:sound_write, @bench.per_op("beep", 100, 2, 4) { |b, _xv| b.beep 440 } /
                            IR::CostModel::BEEP_WRITES,
              note: "one sound-register write")

        # The software mixer: cost is a floor plus a rate per voice, so two voice counts fit the
        # line and the floor falls out of it.
        slope, base = Reductions.fit(1, @bench.mixer_busy(1), 8, @bench.mixer_busy(8))
        weigh(:mix_voice_sample, slope / Benchmarks::MIXER_SPF,
              varies: :mixer_voices, from: 1, to: 8,
              note: "mixing one sample of one sounding voice")
        weigh(:mix_overhead_sample, base / Benchmarks::MIXER_SPF,
              varies: :mixer_voices, from: 1, to: 8,
              note: "the mixer's per-sample cost with no voice sounding")

        # Music: a 2-voice tune minus a 1-voice one isolates one voice; the per-song counter
        # overhead cancels.
        weigh(:music_voice, @bench.music_busy(2) - @bench.music_busy(1),
              varies: :music_voices, from: 1, to: 2,
              note: "one active music voice, per frame")
      end

      # --- the transfer engine ---

      def dma
        # Per pixel: a wide fill's stall minus a narrow fill's stall at the SAME height cancels
        # everything per-row (the row count is equal), leaving the per-pixel transfer over the
        # extra pixels. The wall-clock probe sees this stall the busy count cannot.
        #
        # Measured FIRST because the start-up below is found by taking this out of a row's stall.
        dma_pixel = Reductions.marginal(@bench.dma_stall(200, 100, 4), @bench.dma_stall(40, 100, 4),
                                        over: (200 - 40) * 100 * 4)

        # STARTING one row's transfer costs on BOTH sides of the line the probe draws, so both
        # sides are measured.
        #
        # The CPU writes a few registers to kick the engine off. That is busy time, on a fill two
        # pixels wide so the transfer itself is negligible.
        cpu_start = Reductions.marginal(@bench.dma_fill_busy(2, 40, 15), @bench.dma_fill_busy(2, 8, 15),
                                        over: (40 - 8) * 15)
        # Then the engine takes a fixed moment of its own before the first pixel moves, and the
        # CPU is STALLED through it — not executing — so the busy count cannot see it. Nor can
        # the per-pixel weight: that is a marginal rate measured at a fixed row count, so it
        # excludes the start-up by construction. It fell between the two and was charged by
        # neither. Taking a row's own pixels back out of the stall per row leaves it, with
        # nothing double-counted.
        #
        # It is about a ninth of the register writes: nothing on one wide row, real on a
        # rectangle of forty short ones, where there is nothing to spread it over.
        engine_start = Reductions.residual(
          Reductions.marginal(@bench.dma_stall(8, 40, 4), @bench.dma_stall(8, 20, 4), over: (40 - 20) * 4),
          8 * dma_pixel
        )
        # The two halves are KEPT APART rather than added into one figure, because they behave
        # differently in the one place it matters. Code kept in the console's quick memory runs
        # about two and a half times faster, and the register writes get all of that. The engine
        # does not: the CPU is stopped while it copies, so where our instructions live changes
        # nothing about how long that takes. Added together, a whole-screen clear read a third of
        # its true cost the moment the game loop moved. See Pricing::ENGINE_WEIGHTS.
        weigh(:dma_cpu_start, cpu_start, varies: :dma_rows, from: 8, to: 40,
                                         note: "starting one row's transfer: the register writes, on the CPU")
        weigh(:dma_engine_start, engine_start, varies: :dma_rows, from: 8, to: 40,
                                               note: "the engine's own moment before a row's first pixel moves, as stall")
        weigh(:dma_pixel, dma_pixel, varies: :dma_row_pixels, from: 40, to: 200,
                                     note: "one pixel of a transfer, as engine stall")
      end

      # --- tiled per-frame upkeep ---

      def tiled_upkeep
        weigh(:obj_write, Reductions.marginal(@bench.sprites_busy(64), @bench.sprites_busy(8), over: 64 - 8),
              varies: :sprites, from: 8, to: 64,
              note: "rewriting one sprite's position each frame")
        # ...and holding a placed fade off one of them, which is what a game does when it fades
        # out and leaves its HUD readable. Measured against the SAME sprites drawn with no fade
        # over them, so the sprite writes cancel and what is left is the window twin each kept
        # sprite gets.
        #
        # A TWIN IS NOT A SECOND SPRITE, and this weight exists to say how much less it is.
        # Where it stands, which pose it holds and how big it is are the sprite's own — worked
        # out once and copied into the twin's slot on the way past — plus one test of where the
        # fade is sitting. Measured, that is about four fifths of a whole sprite write, and a
        # whole sprite write is what the model charged for it before this was measured.
        #
        # IT IS DEARER THAN THE EMITTED CODE SUGGESTS, which is the reason to measure it rather
        # than count it. In the ROM a twin is a little over half of what a sprite adds — but
        # what a sprite adds to the ROM includes the parts a frame never runs: uploading its
        # picture, and setting up the variables it keeps its position in. A per-frame rate can
        # only come from a frame.
        #
        # ONE SPRITE STAYS BELOW THE LINE in the fading ROM, so 64 sprites make 63 twins: a
        # fade that keeps every sprite has nothing left to fade and makes none at all. See
        # Benchmarks#sprites_busy.
        kept = Benchmarks::KEPT_SPRITES
        weigh(:obj_window_write,
              Reductions.marginal(@bench.sprites_busy(kept, kept: true), @bench.sprites_busy(kept),
                                  over: kept - 1),
              varies: :kept_sprites, from: kept - 1, to: kept - 1,
              note: "holding a placed fade off one sprite, on top of drawing that sprite")
        # MOVING ONE BACKGROUND'S WINDOW, which is two register writes and nothing else.
        # Measured over how many backgrounds scroll rather than how often a game scrolls one,
        # because the write is made once a frame per background however often it was asked for
        # — see Benchmarks#scroll_busy, where that is the whole point of the recipe.
        #
        # MINUS the two variables it reads. The window's left edge and its top edge are kept in
        # a variable each, and the model charges a variable read where it finds the read (see
        # #operand_read), so a background that scrolls would otherwise pay for reaching its own
        # position twice.
        weigh(:scroll_write,
              Reductions.marginal(@bench.scroll_busy(4), @bench.scroll_busy(1), over: 4 - 1) -
                (2 * operand_read),
              varies: :scrolling_backgrounds, from: 1, to: 4,
              note: "moving one background's window, apart from reading where it sits")
      end

      # A sprite that turns, or changes size, is drawn through one of the display's 32
      # rotate/resize groups instead of straight, and that group is refilled every frame. Both
      # weights are measured against the SAME number of sprites, so only the shape of the draw
      # differs and the count cancels. 32 is the most the display can do at once.
      def affine_sprites
        n = Benchmarks::AFFINE_SPRITES
        turning = @bench.sprites_busy(n, turn: true)
        weigh(:obj_turn, Reductions.marginal(turning, @bench.sprites_busy(n), over: n),
              varies: :turning_sprites, from: n, to: n,
              note: "drawing one sprite through a rotate/resize group instead of straight")
        # ...and on top of that, working out one over the size. That is a division the framework
        # does for the author (Drawing#emit_object_scale_reciprocal), so it is measured against a
        # sprite that already turns — leaving the division and the two multiplies alone.
        weigh(:obj_resize,
              Reductions.marginal(@bench.sprites_busy(n, turn: true, resize: true), turning, over: n),
              varies: :turning_sprites, from: n, to: n,
              note: "working out one over a resized sprite's size, on top of turning")
      end

      # --- interrupts ---

      def interrupts
        lines = IR::CostModel::LINES_PER_FRAME
        rows = IR::CostModel::VISIBLE_LINES

        # BENDING A BACKGROUND ROW BY ROW. All 160 rows are worked out at the frame boundary
        # into a table whichever way they then reach the display, so the two weights here are
        # the table and the reading of it, and ONE SWEEP over how many layers bend gives both.
        #
        # THE TABLE first. What this weighs is the loop that fills one, the writes into it, and
        # the copying engine's own moment on each line. Swept over how many layers bend, not
        # over one layer against none, because that is the thing the model assumes and so the
        # thing to measure: it charges a table per bending layer, so three layers had better
        # cost three times one. Over the rows the extra layers add, since the rate is per row.
        low, high = Benchmarks::BEND_LAYERS.first, Benchmarks::BEND_LAYERS[2]
        weigh(:bend_row_copied,
              Reductions.marginal(@bench.bend_layers_busy(high), @bench.bend_layers_busy(low),
                                  over: (high - low) * rows),
              varies: :bending_layers, from: low, to: high,
              note: "one row of one bending layer's table, filled from the cartridge")
        # ...and the same with the frame's own body kept in the console's quick memory, which is
        # where a real build puts a body this busy. Two weights rather than one and a discount,
        # because the engine's share of it is the console's own work and gets no faster wherever
        # our code lives — the same reason the pair below is a pair.
        weigh(:bend_row_copied_fast,
              Reductions.marginal(@bench.bend_layers_busy(high, fast: true),
                                  @bench.bend_layers_busy(low, fast: true), over: (high - low) * rows),
              varies: :bending_layers, from: low, to: high,
              note: "the same, from the quick memory")

        # THE INTERRUPT, which is what a bend gets when no engine was free to feed it: what ONE
        # line costs. The display announces the end of every line it draws, all 228 of them, and
        # each announcement stops the game, saves registers, reads that line's offset out of the
        # table, writes it and resumes. That fixed cost is the bulk of it, which is why it gets
        # a weight of its own rather than being folded into the arithmetic. Divided over every
        # line the display counts, not just the visible ones: the interrupt fires below the
        # picture too.
        #
        # The line count is always exactly 228, so there is no regime to leave: a program cannot
        # ask the display to draw a different number of lines.
        weigh(:bend_line, bare_interrupt(fast: false) / lines,
              varies: :lines_per_frame, from: lines, to: lines,
              note: "one line's interrupt, handler in the cartridge")
        # ...and the same line with the handler kept in the console's quick memory, which is what
        # a real build does with it.
        weigh(:bend_line_fast, bare_interrupt(fast: true) / lines,
              varies: :lines_per_frame, from: lines, to: lines,
              note: "the same, handler in the quick memory")

        # A timer's tick: the other place a program is interrupted often. Cheaper per interrupt
        # than a line's bend (which reads the scanline counter, works a row out and writes a
        # register on top), and the same two cases.
        #
        # Measured at ONE rate, so its domain is a single point rather than a range. Measured
        # separately at 1000 and 4000 a second it comes out within 3%, so a slower timer is not
        # far wrong — but the domain says a point because a point is what was measured.
        per_frame = Benchmarks::TICKS_PER_FRAME
        weigh(:tick_interrupt,
              Reductions.marginal(@bench.tick_busy(true), @bench.tick_busy(false), over: per_frame),
              varies: :ticks_per_frame, from: per_frame, to: per_frame,
              note: "one timer tick's interrupt, handler in the cartridge")
        weigh(:tick_interrupt_fast,
              Reductions.marginal(@bench.tick_busy(true, fast: true), @bench.tick_busy(false, fast: true),
                                  over: per_frame),
              varies: :ticks_per_frame, from: per_frame, to: per_frame,
              note: "the same, handler in the quick memory")
      end

      # What a frame of bare interrupts costs, with the table it reads from taken back out.
      #
      # A FOURTH bending layer costs two things at once: one more table, and the whole
      # interrupt, since four is one more layer than there are copying engines to feed them.
      # A THIRD costs one more table and nothing else. So the step from three layers to four,
      # less the step from two to three, is the interrupt on its own — measured against its
      # own neighbour rather than against a modelled table, and adjacent so that a later
      # layer's table reaching further into memory cancels as well.
      def bare_interrupt(fast:)
        two, three, four = Benchmarks::BEND_LAYERS.last(3).map { |n| @bench.bend_layers_busy(n, fast: fast) }
        (four - three) - (three - two)
      end

      # --- what the DISPLAY is told to show, without redrawing a pixel ---
      #
      # Both are a handful of register writes, and both are only safe in the vblank window, so
      # both are drawing. `shake_screen` moves the camera every frame it runs, which is what
      # makes the camera worth a weight rather than a shrug. The fade is measured at a level
      # written into the program; a level the game works out costs the conversion on top.
      def display_registers
        weigh(:camera_move, @bench.per_op("cam", 100, 2, 6) { |b, _xv| b.camera 3, 5 },
              note: "moving the visible window over the picture")
        weigh(:fade_set, @bench.per_op("fade", 100, 2, 6) { |b, _xv| b.fade :black, 50 },
              note: "setting the fade level, from a number written in the program")
        weigh(:tint_set, @bench.per_op("tint", 100, 2, 6) { |b, _xv| b.tint :red, 50 },
              note: "setting the tint level, from a color and a number written in the program")
        palette_tint
      end

      # A screen drawn through a COLOR TABLE cannot be tinted by the display's own blend
      # (the color it would blend against is the table's own first entry), so the framework
      # moves every entry of the table instead. Two numbers, because a game pays one of them
      # on nearly every frame and the other only when the tint actually moves.
      #
      # Both ROMs of the per-entry pair paint the same number of pixels and hold the same
      # number of them in the table's low entries — only how many DISTINCT colors they use
      # differs — so the drawing, which happens once at boot anyway, cancels exactly.
      PALETTE_TINT_LO = 32
      PALETTE_TINT_HI = 224

      def palette_tint
        lo = PALETTE_TINT_LO
        hi = PALETTE_TINT_HI
        weigh(:tint_entry,
              Reductions.marginal(@bench.palette_tint_busy(hi), @bench.palette_tint_busy(lo),
                                  over: hi - lo),
              varies: :colors, from: lo, to: hi,
              note: "one color of the table moved toward the tint, on a frame where the tint moved")
        weigh(:tint_hold, @bench.per_op_palette("ptinth", 100, 2, 6) { |b, _lv| b.tint :red, 50 },
              note: "asking for a tint that has not moved — the check that skips the table")
      end

      def saving
        weigh(:save_write,
              Reductions.marginal(@bench.save_busy(60, 4, persist: true),
                                  @bench.save_busy(60, 4, persist: false), over: 60 * 4),
              note: "mirroring one change to a saved variable back to save memory")
      end

      # --- the tear-free screen's own drawing shapes ---
      #
      # Every one of these is measured on that screen, because the same verb emits something
      # else entirely on the direct-color one.
      def tearfree_screen
        # A moving rectangle walks its rows, and a row is built out of PARTS: a spliced near
        # end, a middle, a spliced far end. Five shapes of one row separate them, because each
        # shape adds exactly one thing to the one before it. Every rectangle here is 20 to a
        # frame at two heights, so the once-per-rectangle preamble cancels and only rows are
        # left. The columns are written into the program, so which parts a row has is settled.
        #
        #   even w=2   the row itself + one pair
        #   even w=8   the row itself + four pairs         -> a pair
        #   even w=1   the row itself + a FAR end          -> the far end
        #   even w=3   the same + a second part            -> reaching a part
        #   odd  w=1   the row itself + a NEAR end         -> the near end
        #
        # The two ends are not alike and neither is charged for the other: the near one has to
        # clear a bit to name the pair its pixel sits in, which the far one gets for free.
        # Charging one figure for both, and charging the address work once for a row however
        # many parts it had, is what made a rectangle at an odd column read at seven tenths.
        row_w2 = @bench.tearfree_row_cost("tfr2", 20, 4, 20) { |b, xv, yv, h| b.draw_rect_at xv, yv, 2, h, :red }
        row_w8 = @bench.tearfree_row_cost("tfr8", 20, 4, 20) { |b, xv, yv, h| b.draw_rect_at xv, yv, 8, h, :red }
        row_w1 = @bench.tearfree_row_cost("tfr1", 20, 4, 20) { |b, xv, yv, h| b.draw_rect_at xv, yv, 1, h, :red }
        row_w3 = @bench.tearfree_row_cost("tfr3", 20, 4, 20) { |b, xv, yv, h| b.draw_rect_at xv, yv, 3, h, :red }
        row_odd = @bench.tearfree_row_cost("tfro", 20, 4, 20) { |b, _xv, yv, h| b.draw_rect_at 41, yv, 1, h, :red }
        weigh(:tearfree_pair, (row_w8 - row_w2) / 3.0, # 4 pairs against 1
              varies: :rect_rows, from: 4, to: 20, note: "a side-by-side pair of pixels written straight out")
        weigh(:tearfree_row, row_w2 - @weights[:tearfree_pair],
              varies: :rect_rows, from: 4, to: 20, note: "reaching one row of a moving rectangle, and its first part")
        weigh(:tearfree_edge, row_w1 - @weights[:tearfree_row],
              varies: :rect_rows, from: 4, to: 20, note: "a lone pixel read and spliced back at a row's FAR end")
        weigh(:tearfree_edge_near, row_odd - @weights[:tearfree_row],
              varies: :rect_rows, from: 4, to: 20, note: "the same at the NEAR end, which must name its pair first")
        weigh(:tearfree_part, Reductions.residual(row_w3, row_w2, @weights[:tearfree_edge]),
              varies: :rect_rows, from: 4, to: 20, note: "reaching a second or later part of the same row")

        # What a rectangle costs before its first row. A moving one pays much more of this than a
        # fixed one: its position has to be worked out and its column's parity tested.
        #
        # TWO OPERANDS COME BACK OUT, as they do for a blit and for the same reason: this is
        # the one reading here taken over COPIES of the rectangle rather than over its rows, so
        # it is the only one that pays for reading the position at all.
        weigh(:tearfree_moving_start,
              Reductions.residual(
                @bench.tearfree_rect_cost("tfms", 20) { |b, xv, yv| b.draw_rect_at xv, yv, 8, 8, :red },
                8 * (@weights[:tearfree_row] + (4 * @weights[:tearfree_pair])), 2 * operand_read
              ),
              note: "what a moving rectangle costs before its first row, apart from reaching its position")
        # A fixed rectangle hands every row to the block-fill engine, so its rows measure what
        # starting that engine costs here — the same shape dma_setup measures on the other screen.
        fill_row = @bench.tearfree_row_cost("tff", 20, 4, 20) { |b, _xv, _yv, h| b.fill_rect 0, 0, 8, h, :red }
        weigh(:tearfree_rect_start,
              Reductions.residual(
                @bench.tearfree_rect_cost("tffs", 20) { |b, _xv, _yv| b.fill_rect 0, 0, 8, 8, :red },
                8 * fill_row
              ),
              note: "what a fixed rectangle costs before its first row")
        # The transfer itself, which the CPU never executes — it is stalled while the engine runs.
        weigh(:tearfree_fill_pixel,
              Reductions.marginal(@bench.tearfree_fill_stall(80, 2), @bench.tearfree_fill_stall(10, 2),
                                  over: 240 * 70 * 2),
              varies: :fill_rows, from: 10, to: 80, note: "one pixel of a block fill, as engine stall")

        # A row of a MOVING rectangle whose middle is wide enough to hand to the engine. It gets
        # its own start weight rather than borrowing the fixed rectangle's, because the two are
        # not the same work: a moving rectangle steps its destination along where a fixed one
        # rebuilds it, and charging both the step and the rebuild paid for the address twice.
        #
        # Measured at an EVEN column, which splices neither end, so nothing but the row and its
        # fill is in the reading. The odd column needs no measurement of its own any more: its
        # ends are the same emitted code as a written-out row's, so they are the weights above,
        # and its extra parts are `tearfree_part`. That is what the fix to the odd column was —
        # measure each piece once and count the pieces, rather than one averaged figure per shape.
        #
        # BOTH CLOCKS, split the way the other screen's transfer is: the register writes are the
        # CPU's and get faster when the build moves the code, the copy is the engine's and never
        # does. Reading only the total charged the engine's own moment as if it were code.
        w = Benchmarks::ENGINE_W
        weigh(:tearfree_engine_start,
              Reductions.residual(@bench.tearfree_engine_row("tfee", 40, w, 4, 10, 40),
                                  @weights[:tearfree_row]),
              varies: :rect_rows, from: 10, to: 40,
              note: "starting one row's block fill: the register writes, on the CPU")
        weigh(:tearfree_engine_stall,
              Reductions.residual(@bench.tearfree_engine_row("tfes", 40, w, 4, 10, 40, clock: :stall),
                                  w * @weights[:tearfree_fill_pixel]),
              varies: :rect_rows, from: 10, to: 40,
              note: "the engine's own moment before that row's first pixel moves, as stall")

        # One pixel drawn on its own, and one lit pixel of a font glyph. Both are
        # read-modify-write here (a pixel shares its 16 bits with its neighbour); the lone one
        # also has to find the hidden page's address, which a line of text holds for the line.
        weigh(:tearfree_pixel,
              Reductions.marginal(
                @bench.tearfree_busy("tfp8", 150) { |b, _xv, _yv| 8.times { b.pixel 10, 10, :red } },
                @bench.tearfree_busy("tfp4", 150) { |b, _xv, _yv| 4.times { b.pixel 10, 10, :red } },
                over: 150 * 4
              ),
              note: "a pixel drawn on its own, on the tear-free screen")
        # Drawn HALFWAY DOWN the screen, on purpose. Forming the address of a pixel takes one
        # instruction near the top of the screen and two below it, so text at y=0 is the one
        # cheap case and everywhere else costs about a seventh more. Measuring at the top would
        # under-charge every line of text that is not the first.
        font = Fonts.get(:default)
        y = Benchmarks::GLYPH_Y
        weigh(:tearfree_glyph,
              Reductions.marginal(
                @bench.tearfree_busy("tfg4", 30) { |b, _xv, _yv| b.draw_text "ABCD", 0, y, :red },
                @bench.tearfree_busy("tfg2", 30) { |b, _xv, _yv| b.draw_text "AB", 0, y, :red },
                over: 30 * (font.text_pixels("ABCD") - font.text_pixels("AB"))
              ),
              note: "a lit pixel of a glyph, on the tear-free screen, halfway down")
      end

      # --- per-pixel collision ---

      def collision
        # A bigger overlap walks more pixels: fully overlapped opposite checkerboards force the
        # full size x size walk.
        weigh(:overlap_pixel,
              Reductions.marginal(@bench.overlap_busy(16, 2), @bench.overlap_busy(8, 2),
                                  over: ((16 * 16) - (8 * 8)) * 2),
              varies: :overlap_pixels, from: 8 * 8, to: 16 * 16,
              note: "one pixel of a per-pixel collision walk")
      end

      # --- how much faster the same code runs from the console's quick memory ---
      #
      # Every weight above is what an op costs from the cartridge. A routine the build keeps in
      # the quick memory runs the SAME instructions with nothing to wait for on the way in, so
      # its whole cost scales by one number — this one — and Pricing divides by it for the
      # routines that moved. Without it the estimate would read nearly three times over for any
      # program whose loop got moved, which is most of them.
      def fast_memory
        weigh(:fast_code_speedup,
              Reductions.ratio(@bench.speedup_busy(false), @bench.speedup_busy(true)),
              note: "how many times faster the same code runs from the quick memory")
      end
    end
  end
end

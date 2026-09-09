# frozen_string_literal: true

require "stringio"
require_relative "reductions"

module RubyGBA
  module Calibration
    # The ROMs a calibration measures. One method per scenario: build a program that does a
    # known amount of one thing, hand it to the measurer, get scanlines back.
    #
    # Nothing here touches the emulator directly — it goes through whatever {Measurer} it was
    # given — so the whole set can be exercised against canned readings.
    #
    # Every ROM here keeps its code in the cartridge by default, and that matters more than it
    # looks. A normal build works out which routines are worth keeping in the console's quick
    # memory and puts them there, where the same code runs two to four times faster — including
    # the measuring loops below. Left on, it would quietly rescale every weight in the file to
    # "code in quick memory", and then a program whose routines did NOT fit would be
    # under-charged by that factor. So the weights describe the slow case.
    #
    # The whole set is then run a SECOND time with `fast: true`, and dividing one run by the
    # other says what the quick memory buys each op — see #initialize and Calibrator#gains.
    # The two interrupt weights are outside that: they are measured both ways by recipes of
    # their own, because how much a handler gains is not the general answer.
    class Benchmarks
      MIXER_RATE = IR::CostModel::DEFAULT_MIXER_RATE       # 8192
      MIXER_SPF = ((MIXER_RATE + 59) / 60)                 # samples the mixer fills a frame

      # A rectangle and a glyph are measured HALFWAY DOWN THE SCREEN, on purpose, and this is
      # not a detail: the address of each pixel is worked out while building, and a bigger
      # number takes an instruction more to load. Measured, a pixel of a run costs 0.0121 on
      # the top four rows, 0.0129 over the 82% of the screen from there down to row 136, and
      # 0.0161 below that (where a row's distance into the picture stops fitting in sixteen
      # bits). So the top of the screen is the one atypical place to measure, and the middle is
      # where almost all drawing happens.
      FILL_Y = 80
      DEEP_Y = 145 # far enough down that a row's distance into the picture needs an extra byte
      GLYPH_Y = 80

      BLIT_W = 64
      DIGIT_LO = 2
      DIGIT_HI = 6
      ENGINE_W = 40
      AFFINE_SPRITES = 32 # the most the display can rotate/resize at once
      # And the most sprites that can be kept out of a placed fade: each kept one takes a
      # second slot in the table of 128, so 64 sprites and their 63 windows is the ceiling.
      # It is also the count obj_write's own high end is measured at, so the two share a ROM.
      KEPT_SPRITES = 64
      SPEEDUP_OPS = 40
      TICK_HZ = 8000
      TICKS_PER_FRAME = TICK_HZ / 60.0

      # WHICH MEMORY THE CODE UNDER TEST RUNS FROM. Every weight in the model describes code
      # running from the cartridge, so that is the default and the whole file reads as before.
      #
      # Built with +fast+, the very same recipes measure the very same ops with the build free
      # to keep them in the console's quick memory — and dividing one run by the other is what
      # the quick memory buys THAT op. It is not one number: measured over eleven bodies it
      # runs from about 1.6 for code that is nearly all loads and stores to about 4 for code
      # that stays in registers. See Calibrator#gains.
      #
      # RUNNING THE WHOLE FILE TWICE rather than adding a second recipe per weight, because a
      # second recipe is a second thing to keep in step with the first. The recipes are the
      # same by construction, so the ratio compares like with like and no weight can be given
      # a gain that was measured on a different program from its cost.
      def initialize(measurer, fast: false)
        @m = measurer
        @fast = fast
        @unmoved = 0
      end

      # HOW MANY ROMS ASKED TO RUN FROM THE QUICK MEMORY DID NOT GO. Counted here, where every
      # build passes, because a gain divided out of a ROM that never moved is 1.000 by
      # construction rather than by measurement — and there is exactly one way to be sure which
      # happened, which is to ask the build.
      #
      # It is not hypothetical: three recipes force a loop into its memory-kept shape with a
      # `raw` escape hatch, since that is the only blocker that costs nothing, and a routine
      # holding raw instructions is one {Placement} will not move. See Calibrator#weigh.
      attr_reader :unmoved

      # --- how a ROM gets built and measured ---

      def cartridge_build(name, &block)
        went(RubyGBA.build(name, code: code_for(name), maker: "01", fast_code: @fast,
                                 err: StringIO.new, &block))
      end

      def went(rom)
        @unmoved += 1 if @fast && rom.placement&.funcs.to_a.empty?
        rom
      end

      # The same, built the way a REAL game is built — the build free to keep hot routines in
      # the console's quick memory. Only the interrupt weights use this, and only to measure
      # their own second case.
      def real_build(name, &block)
        RubyGBA.build(name, code: code_for(name), maker: "01", err: StringIO.new, &block)
      end

      def code_for(name) = name[0, 4].upcase.ljust(4, "X")

      # A cartridge from a program built straight out of the IR, for the recipes whose node the
      # DSL will not let them write. Same memory choice as every other ROM here.
      def lowered(name, prog)
        backend = IR::Backends::GBA.new(fast_code: @fast)
        rom = ROM.assemble(backend.lower(prog), title: name, code: code_for(name), maker: "01",
                           built: backend.build_record(prog))
        went(rom)
      end

      # Build a ROM whose game loop runs +body+ (given the builder and the value handles)
      # +repeat_n+ times a frame, and return the scanlines of CPU it burns per frame.
      #
      # THERE USED TO BE A SPARE VARIABLE DECLARED FIRST AND NEVER USED, and its going is worth
      # a note, because it is the proof of something. Reaching a variable once began by building
      # its whole address, and the first variable of a program sat where the console could build
      # that address in one instruction while every later one took two or three — so a statement
      # touching the first variable was cheaper, at each end, than the same statement anywhere
      # else. Exactly one variable in a program was like that, so a spare took the lucky slot
      # and the measured ones sat where a game's variables sit.
      #
      # A read now names the base of the variable memory and carries the distance inside the
      # load, so every variable costs the same to reach and there is no lucky slot to protect.
      def stable_busy(name, repeat_n, &body)
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          xv = var :x, 7
          var :y, 0
          dv = var :d, 100   # a divisor the GAME works out, for the ops that need one
          fv = var :f, 100.5 # and two that hold a fraction, for the ops that divide those
          gv = var :g, 2.5
          enable_sound
          b = self
          game_loop do
            wait_vblank
            repeat(repeat_n) { body.call(b, xv, dv, fv, gv) }
          end
        end
        @m.busy(name, rom)
      end

      # Marginal cost per op: busy with +hi+ copies of the op each pass, minus busy with +lo+,
      # over the extra ops — the op's own cost, with the loop and the overhead cancelled.
      def per_op(name, repeat_n, lo, hi, &one)
        b_lo = stable_busy("#{name}#{lo}", repeat_n) { |*a| lo.times { one.call(*a) } }
        b_hi = stable_busy("#{name}#{hi}", repeat_n) { |*a| hi.times { one.call(*a) } }
        Reductions.marginal(b_hi, b_lo, over: repeat_n * (hi - lo))
      end

      # --- the frame itself ---

      # How many instructions ONE of those plain statements comes to, read off the build
      # rather than counted by hand. The pair above gives scanlines per statement; this is
      # what turns that into scanlines per instruction, and the one thing it must not do is
      # assume a number — the number is what the lowering decides.
      #
      # The statement and its operand together, because that is what the slope measured: a
      # statement's own instructions and the ones that put its operand in front of it.
      #
      # NOTHING IS TIMED HERE, which is why this build is not asked whether it moved: a count
      # of instructions is the same count wherever they run, and a one-statement loop is far
      # too small for the build to think moving worthwhile. Counted as a stuck reading it would
      # take the instruction rate's own gain down with it (see #went).
      def instructions_per_plain_step
        rom = RubyGBA.build("stepinst", code: code_for("stepinst"), maker: "01",
                            fast_code: @fast, err: StringIO.new) do
          screen :bitmap
          n = var :n, 0
          game_loop { n.add 1 }
        end
        emitted = rom.emitted
        step = rom.source_program.walk.find { |node| node.kind == :add }
        step.walk.sum { |node| emitted[node]&.instructions || 0 }
      end

      # A game loop of +ops+ plain statements, one after another, and nothing else at all.
      # Two of these fit the line the frame's own cost falls out of (see Calibrator#frame).
      #
      # No `repeat`: a loop of its own would put its counter in the line, and the base would
      # then be the frame's cost plus entering a loop.
      def plain_frame_busy(ops)
        name = "frame#{ops}"
        rom = cartridge_build(name) do
          screen :bitmap
          n = var :n, 0
          game_loop { ops.times { n.add 1 } }
        end
        @m.busy(name, rom)
      end

      # --- sound ---

      # The mixer's per-frame cost with +n+ looping voices sounding at once.
      def mixer_busy(n)
        name = "mix#{n}"
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          n.times do |i|
            s = sample :"v#{i}", pcm: [30, -30] * 400, rate: MIXER_RATE
            s.play(loop: true)
          end
          game_loop { wait_vblank }
        end
        @m.busy(name, rom)
      end

      # The per-frame cost of playing a song with +n+ voices. The sequencer keeps a cursor per
      # voice and touches only the note currently due each frame, so cost is per active voice,
      # not per note — every voice plays the same 40-note line.
      def music_busy(n)
        name = "mus#{n}"
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          enable_sound
          song(:tune) { tempo 150; n.times { |v| voice(:"p#{v}") { 40.times { note :C4, :sixteenth } } } }
          game_loop { wait_vblank; play_song :tune }
        end
        @m.busy(name, rom)
      end

      # --- direct-color drawing ---

      # One DMA fill of w x h, +per_frame+ times a frame. Each row is a transfer whose fixed
      # CPU setup (the register writes that kick it off) is part of dma_setup; adding rows
      # isolates it. This is the CPU side — the register writes, not the transfer.
      def dma_fill_busy(w, h, per_frame)
        stable_busy("dma#{w}x#{h}", per_frame) { |b, _xv| b.dma_fill_rect 0, 0, w, h, :red }
      end

      # The DMA-STALL scanlines of the same fill: the time the engine spends while the CPU is
      # frozen. It never lands in the busy count (the CPU is stalled, not executing), but it is
      # part of the frame's work. Both parts of the transfer are in here — the engine's fixed
      # start-up and its per-pixel rate — and two measurements separate them.
      def dma_stall(w, h, per_frame)
        name = "dst#{w}x#{h}"
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          b = self
          game_loop { wait_vblank; repeat(per_frame) { b.dma_fill_rect 0, 0, w, h, :red } }
        end
        @m.stall(name, rom)
      end

      # The SAME per-row transfer, with the rectangle's position worked out as the game runs.
      # The fill above folded every row's address in while the program was built; here the CPU
      # has to build one from the live x and y before it can kick the engine off. Growing the
      # height at a fixed width adds rows and nothing else, so the marginal is that per row —
      # and what it has over the fixed fill's row is the whole of the difference.
      def rect_at_busy(w, h, per_frame)
        stable_busy("rat#{w}x#{h}", per_frame) { |b, xv| b.draw_rect_at xv, 0, w, h, :red }
      end

      # ...and again with the row TRIMMED to the screen, which is what a copy that may hang off
      # an edge does before either address is any use: a test at the top and bottom, the visible
      # span worked out at both sides, and both ends of the copy moved to match. A software
      # sprite's save and restore are this, and so is an opaque picture blitted at a worked-out
      # position, which is what this measures because it is the one of the three a game can ask
      # for in a line.
      #
      # THE ART IS SOLID ON PURPOSE, which is the mirror of the note on #blit_busy: a picture
      # with a see-through pixel is drawn a pixel at a time instead of streamed a row at a time,
      # so keeping one here would measure the other shape entirely.
      def opaque_blit_busy(w, h, per_frame)
        name = "obl#{w}x#{h}"
        art = (["#" * w] * h).join("\n")
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          image(:solid, "#" => :red) { art }
          xv = var :bx, 40
          yv = var :by, 20
          b = self
          game_loop { b.wait_vblank; b.repeat(per_frame) { b.blit :solid, xv, yv } }
        end
        @m.busy(name, rom)
      end

      # A rectangle of a fixed size, written straight out — one address and one store a pixel
      # — so growing the WIDTH at a fixed height adds pixels and nothing else.
      def fill_rect_busy(w, h, per_frame, y = FILL_Y)
        stable_busy("fill#{w}x#{h}y#{y}", per_frame) { |b, _xv| b.fill_rect 0, y, w, h, :red }
      end

      # An image with a see-through color, blitted +copies+ times at a position the game works
      # out, with +lit+ pixels of +color+ on each of +rows+ rows. FOUR separate things cost
      # here — the blit, its lit rows, its lit pixels, and whether the color fits inside the
      # instruction that writes it — so all four are variable and each measurement moves one.
      #
      # EVERY ART BUILT HERE KEEPS A SEE-THROUGH PIXEL. Art whose every pixel is lit is not
      # transparent at all — it streams by DMA instead — so differencing across that would be
      # measuring two different things and calling the answer one.
      def blit_busy(lit, rows, per_frame, copies: 1, color: :red)
        name = "blt#{color}#{lit}x#{rows}x#{copies}"
        art = (["#" * lit + "." * (BLIT_W - lit)] * rows).join("\n")
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          image(:art, "#" => color, "." => :transparent) { art }
          xv = var :bx, 40
          yv = var :by, 20
          b = self
          game_loop { b.wait_vblank; b.repeat(per_frame) { copies.times { b.blit :art, xv, yv } } }
        end
        @m.busy(name, rom)
      end

      # --- a live digit ---

      # +copies+ LIVE digits a frame, all showing +digit+, in +font+, on either screen.
      #
      # Built straight from the IR, not through the DSL, and that is the point: `draw_number`
      # also works out WHICH digit each column shows, and the model prices that arithmetic as
      # its own nodes — measuring a whole column would fold it into the digit's weight and
      # charge it twice.
      #
      # Differenced from TWO copies and not one. A program holding a single digit and nothing
      # else at all measures oddly here (150 scanlines against 3.8 for two), which does not
      # happen through the DSL, so it is a quirk of this bare harness rather than of the node.
      def digit_node_busy(digit, copies, font, tear_free)
        name = "dgt#{digit}#{copies}#{font.to_s[0]}#{tear_free ? 'b' : 'd'}"
        b = IR::Build
        prog = b.program(
          b.screen(:bitmap, buffered: tear_free),
          b.set(:d, b.int(digit)),
          b.loop_(b.wait_vblank,
                  *Array.new(copies) { |k| b.draw_digit(b.var_ref(:d), 8, 4 + (k * 9), :white, font: font) }),
        )
        @m.busy(name, lowered(name, prog))
      end

      def per_digit_node(digit, font, tear_free: false)
        Reductions.marginal(digit_node_busy(digit, DIGIT_HI, font, tear_free),
                            digit_node_busy(digit, DIGIT_LO, font, tear_free),
                            over: DIGIT_HI - DIGIT_LO)
      end

      # The box the walk visits for one digit: the widest digit's width, every row of it.
      def self.font_box(font)
        ("0".."9").filter_map { |d| font.glyph_width(d) }.max * font.height
      end

      # --- tiled: sprites, scroll, collision ---

      # Per-frame cost of a per-pixel collision test that walks the WHOLE overlap. The test
      # stops at the first pixel solid in both sprites, so two identical sprites hit at pixel
      # one and never scale. Two opposite checkerboards (A on even cells, B on odd) overlap
      # fully but never coincide, forcing the full size x size walk.
      def overlap_busy(size, per_frame)
        name = "ov#{size}"
        a_art = (0...size).map { |r| (0...size).map { |c| (r + c).even? ? "#" : "." }.join }.join("\n")
        b_art = (0...size).map { |r| (0...size).map { |c| (r + c).odd? ? "#" : "." }.join }.join("\n")
        rom = cartridge_build(name) do
          screen :tiled
          image(:blka, "#" => :red, "." => :transparent) { a_art }
          image(:blkb, "#" => :blue, "." => :transparent) { b_art }
          a = sprite :blka, at: [16, 16]
          b = sprite :blkb, at: [16, 16]
          game_loop { wait_vblank; repeat(per_frame) { a.overlaps?(b).then { set :touch, 1 } } }
        end
        @m.busy(name, rom)
      end

      # Per-frame cost of presenting +n+ hardware sprites — each frame rewrites every sprite's
      # position, so more sprites is more of those writes. One shared 8x8 image.
      #
      # +kept+ builds the same n sprites again, this time with a stack and a fade placed above
      # them, which is a game fading out and leaving its HUD readable. The display cannot say
      # "everything except these sprites" in the register a fade writes — it names every sprite
      # with one bit — so each kept sprite gets a second entry in the sprite table, drawn as a
      # window in the shape of its own pixels, and the fade goes around it. Those extra entries
      # are what the difference between the two ROMs measures.
      #
      # THE FIRST SPRITE STAYS BELOW THE LINE, and that is the recipe rather than a detail: a
      # fade that keeps EVERY sprite has nothing left to fade, so the sprites leave the fade's
      # target list together and no window is made at all. One sprite below leaves n - 1 kept,
      # at the same sprite count on both sides.
      def sprites_busy(n, turn: false, resize: false, kept: false)
        name = "obj#{turn ? 't' : 'u'}#{resize ? 's' : 'p'}#{kept ? 'k' : ''}#{n}"
        rom = cartridge_build(name) do
          screen :tiled
          image(:dot, "#" => :red) { (["#" * 8] * 8).join("\n") }
          spot = ->(i) { [(i % 28) * 8, (i / 28) * 8] }
          # Set once, up front. The angle and the size are then variables the draw reads
          # every frame — which is the cost being measured — with no per-frame `set` of the
          # author's own to muddle it.
          pose = lambda do |s|
            s.face_angle(20) if turn
            s.scale(1.5) if resize
          end
          if kept
            layers :field, :ui
            layer(:field) { pose.call(sprite(:dot, at: spot.call(0))) }
            layer(:ui) { (1...n).each { |i| pose.call(sprite(:dot, at: spot.call(i))) } }
            # Placed once, outside the loop: what is under measurement is the windows the
            # frame writes, not the register the fade itself sets.
            fade :black, 100, under: :ui
          else
            n.times { |i| pose.call(sprite(:dot, at: spot.call(i))) }
          end
          game_loop { wait_vblank }
        end
        @m.busy(name, rom)
      end

      # Per-frame cost of +n+ backgrounds that SCROLL. What varies is how many backgrounds
      # move, not how often a game moves one, and that is the whole recipe.
      #
      # Where the window over a background sits is a pair of display registers, and the
      # display reads them again for every line it draws — so writing them while the picture
      # is being drawn moves the lines below that point and tears the screen in half. The
      # framework writes them once a frame instead, in the gap between frames, whatever the
      # game did during the frame. So a game that scrolls forty times a frame writes them
      # once, exactly like a game that scrolls once, and counting scroll CALLS measures the
      # loop and the statements around them rather than the writes.
      #
      # Which is why `scroll_to` is called ONCE, at boot, and never again: calling it is what
      # tells the build this background is one that moves, and from there the write is made
      # every frame wherever the window happens to sit. The frame under measurement therefore
      # holds the writes and nothing else — no loop, and no statement of the game's own.
      #
      # ONE TO FOUR is not a sample of a range, it is the range: four backgrounds is as many
      # as the display has, and a game that scrolls none pays nothing here. The first
      # background is in both ROMs and cancels, which also keeps the one variable a program
      # has that is cheaper to reach (see #stable_busy) out of the difference.
      def scroll_busy(n)
        name = "scr#{n}"
        rom = cartridge_build(name) do
          screen :tiled
          image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
          tiles :ts, "#" => :t
          n.times do |i|
            background(:"bg#{i}", tiles: :ts, map: Array.new(20, "#" * 30)).scroll_to 0, 0
          end
          game_loop { wait_vblank }
        end
        @m.busy(name, rom)
      end

      # --- loops, division, saving ---

      # What one pass of a `repeat` costs before its body does anything — the counter, the
      # compare and the branch back. Two loops with the same (empty) body and different trip
      # counts difference to the per-pass bookkeeping.
      #
      # Every other weight is measured by #per_op, which varies how many COPIES of an op a
      # pass holds and keeps the trip count fixed — that cancels this cost by construction,
      # correctly for the op's own weight, which is why the loop's own cost needs its own case.
      # A LOOP COMES IN TWO SHAPES and both are measured, because a program gets whichever its
      # body allows. With nothing in the way the counter and the limit stay in registers; a
      # body that can reach other code sends them to memory, where every pass loads and stores
      # them (Backends::GBA::LoopForm decides, and these ROMs are built either side of it).
      #
      # +blocked+ puts one empty instruction of the author's own in the body. It emits nothing
      # at all, so it adds no cost to measure around — and it is the escape hatch, which may
      # use any register, so the loop around it has to go through memory. That is the cheapest
      # honest way to ask for the other shape.
      def loop_busy(per_frame, blocked: false)
        name = "lp#{blocked ? 'm' : 'r'}#{per_frame}"
        @m.busy(name, loop_rom(name, [[per_frame, blocked]]))
      end

      # ...and what a loop costs ONCE, before its first pass. +loops+ separate loops of the
      # same length, so the trip count is fixed and only the number of ENTRIES moves.
      LOOP_START_PASSES = 4 # short enough that entering is a real share, long enough to be a loop

      def loop_start_busy(loops, blocked: false)
        name = "ls#{blocked ? 'm' : 'r'}#{loops}"
        @m.busy(name, loop_rom(name, Array.new(loops) { [LOOP_START_PASSES, blocked] }))
      end

      # ...and the THIRD shape: the counter stays in registers and the pair is saved around the
      # one statement that would land in them. The body is a call, which is what asks for that
      # shape and is also the reason it exists — behaviour in a func, called once per instance,
      # is what the framework tells people to write.
      #
      # +blocked+ puts the empty escape hatch beside the same call, which cannot be bracketed
      # and so sends the loop to memory. So the two ROMs hold the SAME body and differ only in
      # the shape the loop got — the call's own cost is in both and cancels, leaving the two
      # pass weights, out of which the calibrator takes the bracket.
      def loop_spill_busy(per_frame, blocked: false)
        name = "sp#{blocked ? 'm' : 'r'}#{per_frame}"
        @m.busy(name, loop_call_rom(name, per_frame, blocked))
      end

      def loop_call_rom(name, passes, blocked)
        b = IR::Build
        body = [b.call(:__noop)]
        body << b.raw("") if blocked
        prog = b.program(b.screen(:bitmap), b.set(:x, b.int(0)),
                         b.func(:__noop, b.add(:x, b.int(1))),
                         b.loop_(b.wait_vblank, b.repeat(b.int(passes), :__lp, *body)))
        lowered(name, prog)
      end

      # A frame holding the given loops, built straight from the IR: the surface has no way to
      # write an empty escape hatch, and that is what asks for the memory shape.
      def loop_rom(name, loops)
        b = IR::Build
        # Every loop here shares one index name on purpose. Two ROMs holding a different NUMBER
        # of loops are differenced, and a name of its own per loop would put a different number
        # of variables in them too — so the difference would carry those variables' addresses
        # as well as the loop entries being measured. Sharing keeps the variables fixed and the
        # entries the only thing that moves. It is safe because these loops all run one after
        # another and all get the same shape.
        body = loops.map do |passes, blocked|
          b.repeat(b.int(passes), :__lp, *(blocked ? [b.raw("")] : []))
        end
        prog = b.program(b.screen(:bitmap), b.set(:x, b.int(0)), b.loop_(b.wait_vblank, *body))
        lowered(name, prog)
      end

      # A division worked out as the program runs walks the answer one bit at a time, so it is
      # not one price: the routine costs a fixed setup plus a step per bit of the ANSWER.
      # Holding the divisor at 1 and growing the numerator sweeps the answer's width.
      def divide_busy(bits, repeat_n, copies)
        numerator = bits.zero? ? 0 : (2**bits) - 1
        name = "dw#{bits}x#{copies}"
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          n = var :n, numerator
          d = var :d, 1
          var :out, 0
          b = self
          game_loop { b.wait_vblank; b.repeat(repeat_n) { copies.times { b.set :out, (n / d) } } }
        end
        @m.busy(name, rom)
      end

      # What an OPERATOR itself adds, differenced against the same statement with a bare
      # variable in place of the expression. That is the unit the model works in: a statement
      # is charged for itself, and every operator inside it is charged on top — so an
      # operator's weight has to be what it adds and not a whole statement over again.
      #
      # `set :y, x` is the baseline rather than `set :y, 0` because replacing a bare operand
      # is exactly what writing an expression there does. It is also the shape op_assign is
      # measured on, which is what makes the two compose: a statement plus its operators.
      def per_operator(tag, repeat_n: 500, lo: 2, hi: 8, &one)
        per_op(tag, repeat_n, lo, hi, &one) -
          per_op("#{tag}b", repeat_n, lo, hi) { |b, xv| b.set :y, xv }
      end

      # --- a COMPARISON, which the DSL cannot put where the others go ---
      #
      # Every other operator above is measured inside `set :y, <expression>`. A comparison
      # cannot be: on the surface a comparison is a Condition, which belongs to `.then` and
      # cannot be assigned — and wrapping one in a branch to reach it would put the branch's
      # own compare and jump into the reading. So this one is built straight from the IR,
      # which has no such rule, exactly the way #digit_node_busy is.
      #
      # MEASURED ON A COMPARISON THAT ANSWERS FALSE, which is the dearer of its two answers.
      # A comparison is the same four instructions either way, but one of them is a jump that
      # is taken when the answer is false and stepped over when it is true, and a taken jump
      # throws away the instructions being fetched behind it. So a comparison is not one price,
      # and which one a frame pays is not knowable while building — the model takes the worst,
      # the same call it makes for a live digit and a collision walk.
      COMPARE_PASSES = 300 # low enough that the dearest shape stays well inside a frame
      COMPARE_LO = 2
      COMPARE_HI = 8

      def compare_busy(name, copies, &value)
        b = IR::Build
        prog = b.program(
          b.screen(:bitmap),
          # :pad first, keeping the cheap first slot clear — the same reason #stable_busy has one.
          b.set(:pad, b.int(0)), b.set(:y, b.int(0)), b.set(:d, b.int(100)),
          b.loop_(b.wait_vblank,
                  b.repeat(b.int(COMPARE_PASSES), :i, *Array.new(copies) { b.set(:y, value.call) })),
        )
        @m.busy(name, lowered(name, prog))
      end

      # The operator alone, differenced against the same statement holding a bare variable —
      # the unit #per_operator works in, on the harness that can build this node.
      def per_compare_operator(tag, &value)
        compare_rate(tag, &value) - compare_rate("#{tag}b") { IR::Build.var_ref(:d) }
      end

      def compare_rate(tag, &value)
        Reductions.marginal(compare_busy("#{tag}#{COMPARE_HI}", COMPARE_HI, &value),
                            compare_busy("#{tag}#{COMPARE_LO}", COMPARE_LO, &value),
                            over: COMPARE_PASSES * (COMPARE_HI - COMPARE_LO))
      end

      # --- ...AND THE BRANCH THAT ACTS ON THE ANSWER, which is a separate thing ---
      #
      # The comparison above is measured with NO BRANCH round it, deliberately and for a good
      # reason (see its note). So nothing yet prices what an `if` does with the answer: test it
      # and jump over the body when it says no. That is a compare and a jump of its own, and a
      # taken jump throws away the instructions being fetched behind it.
      #
      # THE BODY NEVER RUNS HERE, which is what makes this the branch alone. The comparison is
      # `d > 200` and d holds 100, so every copy tests false, jumps, and leaves its body
      # untouched — so the difference between two counts of them is compares and taken jumps
      # and nothing else. Differenced against the comparison weight afterwards, what is left is
      # the branch.
      #
      # THE TAKEN SIDE IS THE ONE MEASURED because it is the dearer one and because it is the
      # side a walk over slots spends nearly all its time on: a pool of sixty-four with six live
      # jumps fifty-eight times. Where the model knows how often the body runs it charges this
      # for the rest, and where it does not it charges the body every frame instead — which is
      # dearer than this and already covers it.
      BRANCH_PASSES = 300 # the same size the comparison uses, and for the same reason
      BRANCH_LO = 2
      BRANCH_HI = 8

      def branch_busy(name, copies)
        b = IR::Build
        one = -> { b.if_(b.binop(:>, b.var_ref(:d), b.int(200)), b.set(:y, b.int(1))) }
        prog = b.program(
          b.screen(:bitmap),
          # :pad first, keeping the cheap first slot clear — as #stable_busy does.
          b.set(:pad, b.int(0)), b.set(:y, b.int(0)), b.set(:d, b.int(100)),
          b.loop_(b.wait_vblank,
                  b.repeat(b.int(BRANCH_PASSES), :i, *Array.new(copies) { one.call })),
        )
        @m.busy(name, lowered(name, prog))
      end

      # One `if` whose test says no: the comparison, plus the branch's own work.
      def per_branch
        Reductions.marginal(branch_busy("br#{BRANCH_HI}", BRANCH_HI),
                            branch_busy("br#{BRANCH_LO}", BRANCH_LO),
                            over: BRANCH_PASSES * (BRANCH_HI - BRANCH_LO))
      end

      # --- reading a button, and the snapshot behind it ---
      #
      # Built straight from the IR for the reason a comparison is: `held(:a)` hands back a
      # Condition, which belongs to `.then` and cannot be assigned.
      #
      # AND WITH NO `repeat` AROUND IT, which the comparison does have, because the snapshot
      # is read off these same ROMs. The snapshot happens once a FRAME. Three hundred passes
      # would multiply every difference between the two reads by six hundred and leave the
      # snapshot buried under it; written out, a frame with one read of each kind differs by
      # the snapshot and almost nothing else.
      #
      # ONE COPY AND A HUNDRED AND TWENTY. Both counts together give the read's own rate, and
      # the low one on its own gives the snapshot. Read at twenty copies the snapshot comes out
      # a quarter light — a longer run of code lands differently in the cartridge's prefetch —
      # and the instruction count the build emitted says the low reading is the true one.
      #
      # A frame with one read in it is far too cheap for the build to think moving it
      # worthwhile, so these three weights have no measurable GAIN and keep the general figure.
      # That is the right trade: the cost is what a frame pays and the gain is a correction to
      # it, so the clean cost is worth more than the measured correction.
      BUTTON_LO = 1
      BUTTON_HI = 120
      BUTTON_READS = { var: -> { IR::Build.var_ref(:d) },
                       held: -> { IR::Build.held(:a) },
                       pressed: -> { IR::Build.pressed(:a) } }.freeze

      # Every reading the button weights need, in one go: what a frame costs with each count
      # of `set :y, <read>` in it, for a plain variable read, a `held` and a `pressed`.
      def button_reads
        BUTTON_READS.keys.to_h { |kind| [kind, [BUTTON_LO, BUTTON_HI].map { |ops| button_busy(kind, ops) }] }
      end

      def button_busy(kind, ops)
        b = IR::Build
        value = BUTTON_READS.fetch(kind)
        name = "btn#{kind}#{ops}"
        prog = b.program(
          b.screen(:bitmap), b.set(:y, b.int(0)), b.set(:d, b.int(100)),
          b.loop_(b.wait_vblank, *Array.new(ops) { b.set(:y, value.call) })
        )
        @m.busy(name, lowered(name, prog))
      end

      # --- reading one element out of a list or a table ---
      #
      # Reading a plain variable is a couple of instructions, and every statement weight above
      # was measured on a statement that already does one. An indexed read is not that:
      # reaching a list element works out where in the ring it sits (head, wrap, scale to
      # bytes, base) before the load, and reaching a table element makes the index safe first.
      #
      # MEASURED AGAINST SETTING A CONSTANT, so what is left is the WHOLE read. The obvious
      # alternative — charging only the EXTRA over a plain variable read — left every one of
      # these estimating at three quarters of the truth, because the statement weight it is
      # added to is the whole of `set :y, x` and cannot pay for a second read as well. Charging
      # the whole read instead leaves the statement's own absorbed read paid for twice, which
      # is a couple of instructions OVER, and over is the direction to be wrong in.
      #
      # A list's capacity is rounded up to a power of two, so its ring wraps an index with one
      # mask and there is only ever one shape of list read. A TABLE keeps the length it was
      # given, and that decides how an out-of-range index is made safe: a power-of-two table
      # wraps it with a mask, any other size CLAMPS it to the ends with a compare and a branch
      # per bound. So a table read is two shapes, and they are told apart here — pricing the
      # cheap one everywhere would under-charge a table whose length is not a power of two,
      # which is most of the ones a game writes by hand.
      INDEXED_CAPACITY = 64
      CLAMPED_TABLE_LEN = 60 # not a power of two, so its reads clamp instead of wrapping

      def indexed_read_busy(name, kind, copies, per_frame)
        cap = INDEXED_CAPACITY
        clamped_len = CLAMPED_TABLE_LEN
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          xs = list :xs, capacity: cap
          cap.times { |n| xs << n }
          wrapping = table :wrapping, (0...cap).to_a
          clamping = table :clamping, (0...clamped_len).to_a
          out = var :out, 0
          idx = var :idx, 3
          b = self
          game_loop do
            b.wait_vblank
            b.repeat(per_frame) do
              copies.times do
                case kind
                when :none then out.set(0)
                when :list then out.set(xs[idx])
                when :table then out.set(wrapping[idx])
                when :table_clamped then out.set(clamping[idx])
                end
              end
            end
          end
        end
        @m.busy(name, rom)
      end

      # --- reading a list element once per pass of a walk ---
      #
      # A pool's live test and a list's `each` read ONE element per pass, by the loop's own
      # counter, and then test it. That is a different regime from the reads above, which read
      # several elements back to back inside one pass: after the first, the base and the index
      # are already in registers, and the marginal read is cheap in a way a walk never sees.
      # Measured, the read above and a walk's read by the loop counter come out the SAME per
      # element, and a walk on the console pays about a third of it — so the regime is the
      # walk, not the index.
      #
      # So it is measured AS a walk: one pass per slot, against the same walk testing a plain
      # variable instead, so the loop, the test and the branch all cancel and what is left is
      # reaching the element. No more passes than the list has slots, so every read lands
      # inside it — an index off the end takes the other arm of the bounds test.
      #
      # TWO SHAPES, because where the loop's counter lives decides whether the index has to be
      # loaded before the element can be reached. +blocked+ puts the empty escape hatch in the
      # body, which sends the counter to memory (see #loop_rom); the two walks are otherwise
      # the same. Built straight from the IR for that reason.
      WALK_PASSES = 64

      def walk_read_busy(kind, blocked: false)
        name = "walk#{kind}#{blocked ? 'm' : 'r'}"
        b = IR::Build
        cap = WALK_PASSES
        element = kind == :list ? b.list_get(:xs, b.var_ref(:__i)) : b.var_ref(:f)
        body = []
        body << b.raw("") if blocked
        body << b.if_(b.binop(:==, element, b.int(1)), b.add(:t, b.int(1)))
        prog = b.program(b.screen(:bitmap), b.set(:t, b.int(0)), b.set(:f, b.int(0)),
                         b.list_new(:xs, cap), *Array.new(cap) { b.list_push(:xs, b.int(0)) },
                         b.loop_(b.wait_vblank, b.repeat(b.int(cap), :__i, *body)))
        @m.busy(name, lowered(name, prog))
      end

      def per_walk_read(blocked: false)
        Reductions.marginal(walk_read_busy(:list, blocked: blocked), walk_read_busy(:var, blocked: blocked),
                            over: WALK_PASSES)
      end

      # WRITING one element of a list, which is not the same as writing a variable and was
      # charged as one until the two stopped costing alike. A variable is reached from a base
      # this console can hold in a register plus a distance settled while building; an element
      # is reached by working the index out first and adding it, which no base can shorten.
      #
      # The baseline writes a variable the same number of times, so the loop, the value and the
      # statement around it all cancel and what is left is the indexing.
      def indexed_write_busy(name, kind, copies, per_frame)
        cap = INDEXED_CAPACITY
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          xs = list :xs, capacity: cap
          cap.times { |n| xs << n }
          out = var :out, 0
          idx = var :idx, 3
          b = self
          game_loop do
            b.wait_vblank
            b.repeat(per_frame) do
              copies.times { kind == :list ? xs[idx] = 7 : out.set(7) }
            end
          end
        end
        @m.busy(name, rom)
      end

      def per_indexed_write(per_frame: 300, lo: 2, hi: 6)
        wrote = Reductions.marginal(indexed_write_busy("lsw#{hi}", :list, hi, per_frame),
                                    indexed_write_busy("lsw#{lo}", :list, lo, per_frame),
                                    over: per_frame * (hi - lo))
        wrote - Reductions.marginal(indexed_write_busy("vsw#{hi}", :var, hi, per_frame),
                                    indexed_write_busy("vsw#{lo}", :var, lo, per_frame),
                                    over: per_frame * (hi - lo))
      end

      # What one indexed read costs, with the loop and the `set` around it cancelled.
      def per_indexed_read(kind, per_frame: 300, lo: 2, hi: 6)
        tag = kind.to_s[0, 4].delete("_")
        read = Reductions.marginal(indexed_read_busy("#{tag}#{hi}", kind, hi, per_frame),
                                   indexed_read_busy("#{tag}#{lo}", kind, lo, per_frame),
                                   over: per_frame * (hi - lo))
        read - Reductions.marginal(indexed_read_busy("non#{hi}", :none, hi, per_frame),
                                   indexed_read_busy("non#{lo}", :none, lo, per_frame),
                                   over: per_frame * (hi - lo))
      end

      # One division of a +bits+-wide answer, with the loop and the `set` around it cancelled.
      def per_divide(bits, repeat_n = 60)
        Reductions.marginal(divide_busy(bits, repeat_n, 6), divide_busy(bits, repeat_n, 2),
                            over: repeat_n * 4)
      end

      # Per-frame cost of mirroring one persisted variable back to save memory. Every change to
      # a `save_var` emits one of these, right after the change. Two ROMs that differ ONLY in
      # whether the variable is persisted cancel the change itself exactly, leaving what the
      # mirroring adds. Save memory sits on a slow bus and is written a byte at a time, so this
      # is not the couple of instructions it looks like.
      def save_busy(per_frame, copies, persist:)
        name = "sav#{persist ? 's' : 'p'}#{copies}"
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          kept = persist ? save_var(:kept, 0) : var(:kept, 0)
          b = self
          game_loop { b.wait_vblank; b.repeat(per_frame) { copies.times { kept.add 1 } } }
        end
        @m.busy(name, rom)
      end

      # --- the tear-free screen ---
      #
      # It holds a pixel as one BYTE (a number picking a color out of a table) and video memory
      # refuses to write a lone byte, so it draws in shapes the direct-color screen has no
      # counterpart for: pairs of side-by-side pixels written straight out, single pixels read
      # and spliced back, and the block-fill engine for anything wider. Each shape gets its own
      # ROM, and the differencing isolates one of them at a time.
      def tearfree_rom(name, per_frame, &body)
        cartridge_build(name) do
          screen :bitmap, tear_free: true
          xv = var :px, 40 # an EVEN column: no spliced edges unless a case asks for them
          yv = var :py, 10
          b = self
          game_loop { b.wait_vblank; b.repeat(per_frame) { body.call(b, xv, yv) } }
        end
      end

      def tearfree_busy(name, per_frame, &body) = @m.busy(name, tearfree_rom(name, per_frame, &body))

      # --- tinting a screen drawn through a color table ---
      #
      # The tint moves every entry of the table, so what it costs is how many colors the game
      # declared. Both ROMs of the pair paint the SAME number of pixels, once at boot, and
      # differ only in how many distinct colors are among them — so the drawing cancels and
      # what is left is the table.
      #
      # The level alternates between 0 and 100 so the tint MOVES on every frame. Held still it
      # would be skipped, which is the other weight (see #per_op_palette).
      PALETTE_TINT_PIXELS = 224

      def palette_tint_busy(colors)
        name = "ptint#{colors}"
        pixels = PALETTE_TINT_PIXELS
        rom = cartridge_build(name) do
          screen :bitmap, tear_free: true
          level = var :level, 100
          pixels.times { |i| pixel i, 0, (i % colors) + 1 }
          b = self
          game_loop do
            b.wait_vblank
            level.flip
            level.add 100
            b.tint :red, level
          end
        end
        @m.busy(name, rom)
      end

      # Marginal cost per op on a table-drawn screen, for an op that has no counterpart on the
      # direct-color one. The same shape as #per_op, on the other screen.
      def per_op_palette(name, repeat_n, lo, hi, &one)
        b_lo = palette_op_busy("#{name}#{lo}", repeat_n) { |*a| lo.times { one.call(*a) } }
        b_hi = palette_op_busy("#{name}#{hi}", repeat_n) { |*a| hi.times { one.call(*a) } }
        Reductions.marginal(b_hi, b_lo, over: repeat_n * (hi - lo))
      end

      def palette_op_busy(name, repeat_n, &body)
        rom = cartridge_build(name) do
          screen :bitmap, tear_free: true
          lv = var :level, 50
          b = self
          game_loop { b.wait_vblank; b.repeat(repeat_n) { body.call(b, lv) } }
        end
        @m.busy(name, rom)
      end

      # Everything one of these costs: the CPU's own work AND the stall the block-fill engine
      # imposes while it copies, which the busy count cannot see. Needed wherever a shape hands
      # work to the engine, since half of what it costs is on the far side of that line.
      def tearfree_total(name, per_frame, &body) = @m.total(name, tearfree_rom(name, per_frame, &body))

      # Per-ROW cost of a moving rectangle wide enough that its middle goes to the block-fill
      # engine, starting at a column WRITTEN INTO the program so the parity is known. Two
      # heights difference to one row; the once-per-rectangle preamble cancels.
      #
      # Measured on the moving shape itself, and that is the point. A moving rectangle steps
      # its destination along where a fixed one rebuilds it, so a moving row assembled out of
      # the fixed rectangle's weight paid for the address work twice.
      #
      # +clock+ picks which half is wanted. The CPU's register writes and the engine's own
      # copying are separate weights, for the same reason they are on the other screen: only
      # the register writes get faster when the build moves the code.
      def tearfree_engine_row(tag, col, w, per_frame, lo, hi, clock: :busy)
        a = @m.public_send(clock, "#{tag}#{lo}",
                           tearfree_rom("#{tag}#{lo}", per_frame) { |b, _xv, yv| b.draw_rect_at col, yv, w, lo, :red })
        z = @m.public_send(clock, "#{tag}#{hi}",
                           tearfree_rom("#{tag}#{hi}", per_frame) { |b, _xv, yv| b.draw_rect_at col, yv, w, hi, :red })
        Reductions.marginal(z, a, over: per_frame * (hi - lo))
      end

      # Per-ROW cost of a rectangle: two heights of the same rectangle, over the extra rows.
      # The once-per-rectangle preamble is identical in both, so it cancels.
      def tearfree_row_cost(tag, per_frame, lo, hi, &draw)
        a = tearfree_busy("#{tag}#{lo}", per_frame) { |b, xv, yv| draw.call(b, xv, yv, lo) }
        z = tearfree_busy("#{tag}#{hi}", per_frame) { |b, xv, yv| draw.call(b, xv, yv, hi) }
        Reductions.marginal(z, a, over: per_frame * (hi - lo))
      end

      # The WHOLE cost of one rectangle, preamble included: more copies of the same rectangle
      # at a fixed trip count. Subtracting the rows leaves what it costs before the first one.
      def tearfree_rect_cost(tag, per_frame, &draw)
        a = tearfree_busy("#{tag}1", per_frame) { |b, xv, yv| draw.call(b, xv, yv) }
        z = tearfree_busy("#{tag}3", per_frame) { |b, xv, yv| 3.times { draw.call(b, xv, yv) } }
        Reductions.marginal(z, a, over: per_frame * 2)
      end

      # The stall the block-fill engine imposes on the tear-free screen while it copies. It
      # moves 16 bits — two pixels — at a time here, so this is not the direct screen's rate.
      def tearfree_fill_stall(h, per_frame)
        name = "tfs#{h}"
        @m.stall(name, tearfree_rom(name, per_frame) { |b, _xv, _yv| b.fill_rect 0, 0, 240, h, :red })
      end

      # --- a stretched column of a picture ---
      #
      # One ROW of a stretched column, which is what a first-person view is made of. The pair
      # differs only in how TALL the columns are, so the divide that finds the step, the loop
      # around them and reaching the picture all cancel, and what is left is the walk down the
      # screen.
      #
      # Read on BOTH screens, because they do not write a pixel the same way and the answer
      # decides which screen such a view should use. The direct-color one stores a whole color
      # straight out; the tear-free one holds a number per pixel and refuses a lone byte, so
      # every pixel is a read of the pair it shares, a splice of its own half, and a write back.
      #
      # The height is a variable, because a wall's height always is — and the model charges
      # this weight only where the height is a number, so measuring it against one written into
      # the program would measure a case that never charges.
      # Kept small enough that the TALLER of the pair still finishes inside a frame. These
      # weights describe code running from the cartridge, which is where the measuring ROMs
      # put it, and a reading past about 200 scanlines saturates and stops meaning anything.
      COLUMN_PASSES = 20
      COLUMN_SHORT = 8
      COLUMN_TALL = 32

      def column_row_cost(tag, tear_free:, width: 1)
        a = column_busy("#{tag}#{COLUMN_SHORT}", COLUMN_SHORT, tear_free, width)
        z = column_busy("#{tag}#{COLUMN_TALL}", COLUMN_TALL, tear_free, width)
        Reductions.marginal(z, a, over: COLUMN_PASSES * (COLUMN_TALL - COLUMN_SHORT))
      end

      # A strip of this many pixels, for reading what the pixels BESIDE the first cost. Three
      # rather than two because two is the one width that happens to fall exactly on a pair on
      # the tear-free screen, and a weight measured only on the lucky case would under-read.
      COLUMN_STRIP = 3

      # The strips are spread wide enough not to overlap, and at a spacing that lands them on
      # even and odd columns alike — which is what a view drawing strips wider than a pixel
      # does, and on the tear-free screen it is the case that cannot prove which half of a pair
      # it writes.
      def column_busy(name, height, tear_free, width)
        rom = cartridge_build(name) do
          screen :bitmap, tear_free: tear_free
          image :art, width: 8, height: 64, data: Array.new(8 * 64) { |i| i.even? ? :red : :blue }
          tall = var :tall, 0
          game_loop do
            tall.set height
            repeat(COLUMN_PASSES) do |c|
              draw_column_at :art, slice: 0, x: c * COLUMN_STRIP, top: 10, height: tall, width: width
            end
          end
        end
        @m.busy(name, rom)
      end

      # --- interrupts: a bending background, and a timer's tick ---

      # HOW MANY LAYERS BEND across the sweep both bending weights are read from.
      #
      # One layer to three are fed to the display by its own copying engines, which is as
      # many as there are to lend out. A FOURTH is one more than there is an engine for, and
      # then the display is interrupted for every line instead. So one sweep answers both
      # questions: the step from one bending layer to three is a table each and nothing else,
      # and the step from three to four is one more table AND the whole interrupt — take the
      # first step off the second and the interrupt is what is left.
      BEND_LAYERS = [1, 2, 3, 4].freeze

      # FOUR tiled backgrounds, of which +bending+ bend row by row. The offset each row is
      # given is a number written into the program, the cheapest one there is, so nothing of
      # the program's own arithmetic is in the way (the model prices that separately, per
      # visible row).
      #
      # ALL FOUR BACKGROUNDS ARE THERE WHATEVER BENDS, and that is the recipe rather than a
      # detail: the display fetches every layer it is showing whether that layer bends or not,
      # so a pair that differed in how many backgrounds there are would be measuring the
      # display's own work and calling it a table.
      #
      # +fast+ builds the same ROM the way a real one is built, so the build keeps the busiest
      # routines in the console's quick memory. Those are the OTHER weight of each pair, and
      # they have to be measured rather than taken from the general fast-memory factor: a fair
      # share of an interrupt is the console's own doing — stopping the game, handing control
      # over and taking it back — and none of that runs from our memory.
      def bend_layers_busy(bending, fast: false)
        name = "bendl#{bending}#{fast ? 'f' : ''}"
        layers = BEND_LAYERS.max
        rom = build_for(fast, name) do
          screen :tiled
          image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
          tiles :ts, "#" => :t
          layers.times do |i|
            bg = background :"bg#{i}", tiles: :ts, map: Array.new(20, "#" * 30)
            bg.scroll_each_row { |_row| 3 } if i < bending
          end
          game_loop { wait_vblank }
        end
        @m.busy(name, rom)
      end

      # A hardware timer ticking TICK_HZ times a second with a handler that does NOTHING: the
      # bare cost of being interrupted by it, with none of the program's own work in the way
      # (the model prices the handler's body separately, per tick). Differenced against the
      # same ROM with no timer at all. +fast+ is the second case, for the same reason
      # #bend_layers_busy needs one.
      def tick_busy(ticking, fast: false)
        name = "tick#{ticking ? 1 : 0}#{fast ? 'f' : ''}"
        hz = TICK_HZ
        rom = build_for(fast, name) do
          screen :bitmap
          clear_screen :black
          n = var :n, 0
          timer(:beat, per_second: hz).on_tick { } if ticking
          game_loop { n.add 0 }
        end
        @m.busy(name, rom)
      end

      def build_for(fast, name, &block)
        fast ? real_build(name, &block) : cartridge_build(name, &block)
      end

      # --- how much faster the same code runs from the console's quick memory ---
      #
      # Measured on a body of plain steps rather than draws, because this is a property of
      # fetching instructions and nothing else: the same work, in the same order, in the two
      # places it can live.
      def speedup_busy(fast)
        name = "spd#{fast ? 'f' : 's'}"
        ops = SPEEDUP_OPS
        rom = RubyGBA.build(name, code: code_for(name), maker: "01", fast_code: fast,
                                  err: StringIO.new) do
          screen :bitmap
          clear_screen :black
          xv = var :x, 7
          b = self
          game_loop { b.wait_vblank; b.repeat(60) { ops.times { xv.add 1 } } }
        end
        @m.busy(name, rom)
      end
    end
  end
end

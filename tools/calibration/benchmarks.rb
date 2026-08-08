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
    # Every ROM here is built with `fast_code: false`, and that matters more than it looks. A
    # normal build works out which routines are worth keeping in the console's quick memory
    # and puts them there, where the same code runs about two and a half times faster —
    # including the measuring loops below. Left on, it would quietly rescale every weight in
    # the file to "code in quick memory", and then a program whose routines did NOT fit would
    # be under-charged by that factor. So the weights describe the slow case, and how much the
    # quick memory buys is one more measured weight (fast_code_speedup) applied on top. The
    # two exceptions say so where they are: an interrupt handler is measured BOTH ways,
    # because how much it gains is not the general factor.
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
      SPEEDUP_OPS = 40
      TICK_HZ = 8000
      TICKS_PER_FRAME = TICK_HZ / 60.0

      def initialize(measurer)
        @m = measurer
      end

      # --- how a ROM gets built and measured ---

      def cartridge_build(name, &block)
        RubyGBA.build(name, code: code_for(name), maker: "01", fast_code: false,
                            err: StringIO.new, &block)
      end

      # The same, built the way a REAL game is built — the build free to keep hot routines in
      # the console's quick memory. Only the interrupt weights use this, and only to measure
      # their own second case.
      def real_build(name, &block)
        RubyGBA.build(name, code: code_for(name), maker: "01", err: StringIO.new, &block)
      end

      def code_for(name) = name[0, 4].upcase.ljust(4, "X")

      # Build a ROM whose game loop runs +body+ (given the builder and the value handles)
      # +repeat_n+ times a frame, and return the scanlines of CPU it burns per frame.
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
        # fast_code: false for the same reason every other ROM here is built that way.
        rom = ROM.assemble(IR::Backends::GBA.new(fast_code: false).lower(prog),
                           title: name, code: code_for(name), maker: "01")
        @m.busy(name, rom)
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
      def sprites_busy(n, turn: false, resize: false)
        name = "obj#{turn ? 't' : 'u'}#{resize ? 's' : 'p'}#{n}"
        rom = cartridge_build(name) do
          screen :tiled
          image(:dot, "#" => :red) { (["#" * 8] * 8).join("\n") }
          n.times do |i|
            s = sprite :dot, at: [(i % 28) * 8, (i / 28) * 8]
            # Set once, up front. The angle and the size are then variables the draw reads
            # every frame — which is the cost being measured — with no per-frame `set` of the
            # author's own to muddle it.
            s.face_angle(20) if turn
            s.scale(1.5) if resize
          end
          game_loop { wait_vblank }
        end
        @m.busy(name, rom)
      end

      def scroll_busy(per_frame)
        name = "scr#{per_frame}"
        rom = cartridge_build(name) do
          screen :tiled
          image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
          tiles :ts, "#" => :t
          bg = background :bg, tiles: :ts, map: Array.new(20, "#" * 30)
          game_loop { wait_vblank; repeat(per_frame) { bg.scroll_by 1, 0 } }
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
      def loop_busy(per_frame)
        name = "lp#{per_frame}"
        rom = cartridge_build(name) do
          screen :bitmap
          clear_screen :black
          var :x, 0
          b = self
          game_loop { b.wait_vblank; b.repeat(per_frame) { nil } }
        end
        @m.busy(name, rom)
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
      def tearfree_engine_row(tag, col, w, per_frame, lo, hi)
        a = tearfree_total("#{tag}#{lo}", per_frame) { |b, _xv, yv| b.draw_rect_at col, yv, w, lo, :red }
        z = tearfree_total("#{tag}#{hi}", per_frame) { |b, _xv, yv| b.draw_rect_at col, yv, w, hi, :red }
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

      # --- interrupts: a bending background, and a timer's tick ---

      # A tiled background, optionally bending row by row. With +bend+ the display raises an
      # interrupt after every line it draws and the handler writes that line's own scroll
      # offset — so this ROM pays the whole per-line cost 228 times a frame. The offset is a
      # number written into the program, the cheapest one there is, so differencing against the
      # same ROM without the bend leaves the interrupt itself and nothing of the program's own
      # arithmetic (which the model prices separately, per visible line).
      #
      # +fast+ builds the same ROM the way a real one is built, so the build keeps the routine
      # the announcement lands in in the console's quick memory. That is the OTHER weight: the
      # handler runs from fast memory but the console's own part of an interrupt — stopping the
      # game, saving registers, handing over and taking back — does not, so how much it saves
      # has to be measured rather than assumed from the general fast-memory factor.
      def bend_busy(bend, fast: false)
        name = "bend#{bend ? 1 : 0}#{fast ? 'f' : ''}"
        rom = build_for(fast, name) do
          screen :tiled
          image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
          tiles :ts, "#" => :t
          bg = background :bg, tiles: :ts, map: Array.new(20, "#" * 30)
          bg.scroll_each_row { |_row| 3 } if bend
          game_loop { wait_vblank }
        end
        @m.busy(name, rom)
      end

      # A hardware timer ticking TICK_HZ times a second with a handler that does NOTHING: the
      # bare cost of being interrupted by it, with none of the program's own work in the way
      # (the model prices the handler's body separately, per tick). Differenced against the
      # same ROM with no timer at all. +fast+ is the second case, for the same reason
      # #bend_busy needs one.
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

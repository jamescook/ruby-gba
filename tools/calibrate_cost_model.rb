# frozen_string_literal: true

# Calibrate the cost model's per-op weights against the emulator's GBA timing model,
# and WRITE the result as a source-controlled Ruby fixture
# (lib/ruby_gba/ir/measured_weights.rb) that the cost model loads — no hand-copying,
# no JSON/YAML. The numbers are emulated-cycle counts, not host wall-clock time, so
# they are the same on any machine that runs this gemba-core build.
#
# Each weight is the cost, in scanlines, the model charges for one op. We measure
# the real thing: build a ROM whose per-frame loop does an op a known number of
# times, run it on the emulator (gemba-core), and read the cycles it actually
# burns per frame (Probe#busy_scanlines, or #frame_cost for the DMA-stall part).
# Differencing two ROMs that differ only
# in the op under test cancels the fixed per-frame overhead (the game loop, the
# vblank wait, the repeat counter), leaving the op's marginal cost. The
# measurement is only valid while a frame's work fits inside a frame (~228
# scanlines) — past that busy_scanlines caps and wobbles — so the sizes below are
# kept well under that, and #stable_busy re-reads to confirm.
#
# Run it after changing the lowering of a priced op, then commit the diff:
#   ruby tools/calibrate_cost_model.rb

require_relative "../lib/ruby_gba"
require_relative "../gemba-core/lib/gemba_core"
require "tempfile"
require "stringio"

FIXTURE = File.expand_path("../lib/ruby_gba/ir/measured_weights.rb", __dir__)
SETTLE = 8
MIXER_RATE = RubyGBA::IR::CostModel::DEFAULT_MIXER_RATE          # 8192
MIXER_SPF = ((MIXER_RATE + 59) / 60)                            # samples the mixer fills a frame
TFS = []

# Build a ROM whose game loop runs `body` (a proc given the builder and the `x`
# value handle) `repeat_n` times a frame, and return the real scanlines of CPU it
# burns per frame — re-read to confirm it's in the stable (sub-frame) regime.
def stable_busy(name, repeat_n, &body)
  rom = RubyGBA.build(name, code: name[0, 4].upcase.ljust(4, "X"), maker: "01", err: StringIO.new) do
    screen :bitmap
    clear_screen :black
    xv = var :x, 7
    var :y, 0
    dv = var :d, 100 # a divisor the GAME works out, for the ops that need one
    fv = var :f, 100.5 # and two that hold a fraction, for the ops that divide those
    gv = var :g, 2.5
    enable_sound
    b = self
    game_loop do
      wait_vblank
      repeat(repeat_n) { body.call(b, xv, dv, fv, gv) }
    end
  end
  measure(name, rom)
end

def measure(name, rom)
  tf = Tempfile.new([name.downcase, ".gba"]); tf.binmode; rom.write(tf.path); tf.flush
  TFS << tf
  probe = GembaCore.open(tf.path)
  reads = 3.times.map { probe.busy_scanlines(settle: SETTLE) }
  probe.close
  warn "  ! #{name}: unstable reads #{reads.map { |r| r.round(1) }} (frame overflow?)" if reads.max - reads.min > 1.0
  warn "  ! #{name}: #{reads.min.round(1)} scanlines — near the 228 frame ceiling" if reads.min > 200
  reads.min
end

# Marginal cost per op: (busy with `hi` copies of the op each iteration) minus
# (busy with `lo`), over the extra ops — the op's own cost, overhead cancelled.
def per_op(name, repeat_n, lo, hi, &one)
  b_lo = stable_busy("#{name}#{lo}", repeat_n) { |b, xv, dv, fv, gv| lo.times { one.call(b, xv, dv, fv, gv) } }
  b_hi = stable_busy("#{name}#{hi}", repeat_n) { |b, xv, dv, fv, gv| hi.times { one.call(b, xv, dv, fv, gv) } }
  (b_hi - b_lo) / (repeat_n * (hi - lo).to_f)
end

# The mixer's per-frame cost with `n` looping voices sounding at once.
def mixer_busy(n)
  rom = RubyGBA.build("mix#{n}", code: "MX#{n.to_s.rjust(2, '0')}", maker: "01", err: StringIO.new) do
    screen :bitmap
    clear_screen :black
    n.times do |i|
      s = sample :"v#{i}", pcm: [30, -30] * 400, rate: MIXER_RATE
      s.play(loop: true)
    end
    game_loop { wait_vblank }
  end
  measure("mix#{n}", rom)
end

# The per-frame cost of playing a song with `n` voices. The sequencer keeps a
# cursor per voice and touches only the note currently due each frame, so cost is
# per active voice, not per note — every voice plays the same 40-note line.
def music_busy(n)
  rom = RubyGBA.build("mus#{n}", code: "MUS#{n}", maker: "01", err: StringIO.new) do
    screen :bitmap
    clear_screen :black
    enable_sound
    song(:tune) { tempo 150; n.times { |v| voice(:"p#{v}") { 40.times { note :C4, :sixteenth } } } }
    game_loop { wait_vblank; play_song :tune }
  end
  measure("mus#{n}", rom)
end

# One DMA fill of w x h, `per_frame` times a frame. Each row is a transfer whose fixed CPU
# setup (the register writes that kick it off) is part of dma_setup; adding rows isolates
# it. This is the CPU (busy) side — the register writes, not the transfer.
def dma_fill_busy(w, h, per_frame)
  stable_busy("dma#{w}x#{h}", per_frame) { |b, _xv| b.dma_fill_rect 0, 0, w, h, :red }
end

# The DMA-stall scanlines of a w x h fill done `per_frame` times a frame: the time the
# engine spends while the CPU is frozen. It never lands in the busy count (the CPU is
# stalled, not executing), but it is part of the frame's wall-clock work, which #frame_cost
# exposes as the difference between active and busy time. Both parts of the transfer are
# in here — the engine's fixed start-up and its per-pixel rate — and the two measurements
# below separate them.
def dma_stall(w, h, per_frame)
  name = "dst#{w}x#{h}"
  rom = RubyGBA.build(name, code: name[0, 4].upcase.ljust(4, "X"), maker: "01", err: StringIO.new) do
    screen :bitmap
    clear_screen :black
    b = self
    game_loop { wait_vblank; repeat(per_frame) { b.dma_fill_rect 0, 0, w, h, :red } }
  end
  tf = Tempfile.new([name.downcase, ".gba"]); tf.binmode; rom.write(tf.path); tf.flush
  TFS << tf
  probe = GembaCore.open(tf.path)
  reads = 3.times.map { probe.frame_cost(settle: SETTLE).dma_scanlines }
  probe.close
  reads.min
end

# A rectangle of a fixed size on the direct-color screen, `per_frame` times a frame.
# It is written straight out, one address and one store a pixel, so growing the WIDTH at
# a fixed height adds pixels and nothing else.
#
# DRAWN HALFWAY DOWN THE SCREEN, on purpose, and this is not a detail: the address of
# each pixel is worked out while building, and a bigger number takes an instruction more
# to load. Measured, a pixel of a run costs 0.0121 on the top four rows, 0.0129 over the
# 82% of the screen from there down to row 136, and 0.0161 below that (where a row's
# distance into the picture stops fitting in sixteen bits). So the top of the screen is
# the one atypical place to measure, and the middle is where almost all drawing happens.
# A glyph's lit pixel measures the same three numbers at the same three places, which is
# what says the two are one shape and want one weight.
FILL_Y = 80
DEEP_Y = 145 # far enough down that a row's distance into the picture needs an extra byte
def fill_rect_busy(w, h, per_frame, y = FILL_Y)
  stable_busy("fill#{w}x#{h}y#{y}", per_frame) { |b, _xv| b.fill_rect 0, y, w, h, :red }
end

# An image with a see-through color, blitted `copies` times at a position the game works
# out, with `lit` pixels of `color` on each of `rows` rows. FOUR separate things cost here
# — the blit, its lit rows, its lit pixels, and whether the color fits inside the
# instruction that writes it — so all four are variable and each measurement below moves
# exactly one of them.
#
# EVERY ART BUILT HERE KEEPS A SEE-THROUGH PIXEL. Art whose every pixel is lit is not
# transparent at all — it streams by DMA instead — so differencing across that would be
# measuring two different things and calling the answer one.
BLIT_W = 64
def blit_busy(lit, rows, per_frame, copies: 1, color: :red)
  name = "blt#{color}#{lit}x#{rows}x#{copies}"
  art = (["#" * lit + "." * (BLIT_W - lit)] * rows).join("\n")
  rom = RubyGBA.build(name, code: name[0, 4].upcase.ljust(4, "X"), maker: "01", err: StringIO.new) do
    screen :bitmap
    clear_screen :black
    image(:art, "#" => color, "." => :transparent) { art }
    xv = var :bx, 40
    yv = var :by, 20
    b = self
    game_loop { b.wait_vblank; b.repeat(per_frame) { copies.times { b.blit :art, xv, yv } } }
  end
  measure(name, rom)
end

# `copies` LIVE digits a frame, all showing `digit`, in `font`, on either screen.
#
# Built straight from the IR, not through the DSL, and that is the point: `draw_number`
# also works out WHICH digit each column shows, and the model prices that arithmetic as its
# own nodes — measuring a whole column would fold it into the digit's weight and charge it
# twice.
#
# Differenced from TWO copies and not one. A program holding a single digit and nothing
# else at all measures oddly here (150 scanlines against 3.8 for two), which does not
# happen through the DSL, so it is a quirk of this bare harness rather than of the node.
def digit_node_busy(digit, copies, font, tear_free)
  name = "dgt#{digit}#{copies}#{font.to_s[0]}#{tear_free ? 'b' : 'd'}"
  prog = RubyGBA::IR::Build.program(
    RubyGBA::IR::Build.screen(:bitmap, buffered: tear_free),
    RubyGBA::IR::Build.set(:d, RubyGBA::IR::Build.int(digit)),
    RubyGBA::IR::Build.loop_(RubyGBA::IR::Build.wait_vblank,
                             *Array.new(copies) do |k|
                               RubyGBA::IR::Build.draw_digit(RubyGBA::IR::Build.var_ref(:d), 8,
                                                             4 + (k * 9), :white, font: font)
                             end),
  )
  rom = RubyGBA::ROM.assemble(RubyGBA::IR::Backends::GBA.new.lower(prog),
                              title: name, code: name[0, 4].upcase.ljust(4, "X"), maker: "01")
  measure(name, rom)
end

# The box the walk visits for one digit: the widest digit's width, every row of it.
def font_box(font)
  ("0".."9").filter_map { |d| font.glyph_width(d) }.max * font.height
end

DIGIT_LO = 2
DIGIT_HI = 6
def per_digit_node(digit, font, tear_free: false)
  (digit_node_busy(digit, DIGIT_HI, font, tear_free) - digit_node_busy(digit, DIGIT_LO, font, tear_free)) /
    (DIGIT_HI - DIGIT_LO).to_f
end

# Per-frame cost of a per-pixel collision test that walks the WHOLE overlap. The test
# stops at the first pixel solid in both sprites, so two identical sprites hit at pixel
# one and never scale. Two opposite checkerboards (A on even cells, B on odd) overlap
# fully but never coincide, forcing the full size x size walk. Tiled sprites are 8-mult.
def overlap_busy(size, per_frame)
  a_art = (0...size).map { |r| (0...size).map { |c| (r + c).even? ? "#" : "." }.join }.join("\n")
  b_art = (0...size).map { |r| (0...size).map { |c| (r + c).odd? ? "#" : "." }.join }.join("\n")
  rom = RubyGBA.build("ov#{size}", code: "OV#{size.to_s.rjust(2, '0')}", maker: "01", err: StringIO.new) do
    screen :tiled
    image(:blka, "#" => :red, "." => :transparent) { a_art }
    image(:blkb, "#" => :blue, "." => :transparent) { b_art }
    a = sprite :blka, at: [16, 16]
    b = sprite :blkb, at: [16, 16]
    game_loop { wait_vblank; repeat(per_frame) { a.overlaps?(b).then { set :touch, 1 } } }
  end
  measure("ov#{size}", rom)
end

# Per-frame cost of presenting `n` hardware sprites — each frame rewrites every sprite's
# OAM position, so more sprites is more of those writes. One shared 8x8 image.
def sprites_busy(n)
  rom = RubyGBA.build("obj#{n}", code: "OB#{n.to_s.rjust(2, '0')}", maker: "01", err: StringIO.new) do
    screen :tiled
    image(:dot, "#" => :red) { (["#" * 8] * 8).join("\n") }
    n.times { |i| sprite :dot, at: [(i % 28) * 8, (i / 28) * 8] }
    game_loop { wait_vblank }
  end
  measure("obj#{n}", rom)
end

# What one pass of a `repeat` costs before its body does anything — the counter, the
# compare and the branch back. Two loops with the same (empty) body and different trip
# counts difference to the per-pass bookkeeping.
#
# Every other weight here is measured by #per_op, which varies how many COPIES of an op a
# pass holds and keeps the trip count fixed — that cancels this cost by construction,
# correctly for the op's own weight, which is why the loop's own cost needs its own case.
def loop_busy(per_frame)
  rom = RubyGBA.build("lp#{per_frame}", code: "LP#{per_frame.to_s.rjust(2, '0')[0, 2]}", maker: "01",
                                        err: StringIO.new) do
    screen :bitmap
    clear_screen :black
    var :x, 0
    b = self
    game_loop { b.wait_vblank; b.repeat(per_frame) { nil } }
  end
  measure("lp#{per_frame}", rom)
end

# A division worked out as the program runs walks the answer one bit at a time, so it is
# not one price: the routine costs a fixed setup plus a step per bit of the ANSWER.
# Holding the divisor at 1 and growing the numerator sweeps the answer's width.
def divide_busy(bits, repeat_n, copies)
  numerator = bits.zero? ? 0 : (2**bits) - 1
  name = "dw#{bits}x#{copies}"
  rom = RubyGBA.build(name, code: name[0, 4].upcase.ljust(4, "X"), maker: "01", err: StringIO.new) do
    screen :bitmap
    clear_screen :black
    n = var :n, numerator
    d = var :d, 1
    var :out, 0
    b = self
    game_loop { b.wait_vblank; b.repeat(repeat_n) { copies.times { b.set :out, (n / d) } } }
  end
  measure(name, rom)
end

# One division of a `bits`-wide answer, with the loop and the `set` around it cancelled.
def per_divide(bits, repeat_n = 60)
  (divide_busy(bits, repeat_n, 6) - divide_busy(bits, repeat_n, 2)) / (repeat_n * 4.0)
end

# Per-frame cost of mirroring one persisted variable back to save memory. Every change
# to a `save_var` emits one of these, right after the change. Two ROMs that differ ONLY
# in whether the variable is persisted cancel the change itself exactly, leaving what
# the mirroring adds. Save memory sits on a slow bus and is written a byte at a time,
# so this is not the couple of instructions it looks like.
def save_busy(per_frame, copies, persist:)
  name = "sav#{persist ? 's' : 'p'}#{copies}"
  rom = RubyGBA.build(name, code: name[0, 4].upcase.ljust(4, "X"), maker: "01", err: StringIO.new) do
    screen :bitmap
    clear_screen :black
    kept = persist ? save_var(:kept, 0) : var(:kept, 0)
    b = self
    game_loop { b.wait_vblank; b.repeat(per_frame) { copies.times { kept.add 1 } } }
  end
  measure(name, rom)
end

# --- the tear-free screen ---
#
# It holds a pixel as one BYTE (a number picking a color out of a table) and video memory
# refuses to write a lone byte, so it draws in shapes the direct-color screen has no
# counterpart for: pairs of side-by-side pixels written straight out, single pixels read
# and spliced back, and the block-fill engine for anything wider. Each shape gets its own
# ROM below, and the differencing isolates one of them at a time.
def tearfree_rom(name, per_frame, &body)
  RubyGBA.build(name, code: name[0, 4].upcase.ljust(4, "X"), maker: "01", err: StringIO.new) do
    screen :bitmap, tear_free: true
    xv = var :px, 40 # an EVEN column: no spliced edges unless a case asks for them
    yv = var :py, 10
    b = self
    game_loop { b.wait_vblank; b.repeat(per_frame) { body.call(b, xv, yv) } }
  end
end

def tearfree_busy(name, per_frame, &body) = measure(name, tearfree_rom(name, per_frame, &body))

# Everything one of these costs: the CPU's own work AND the stall the block-fill engine
# imposes while it copies, which the busy count cannot see. Needed wherever a shape hands
# work to the engine, since half of what it costs is on the far side of that line.
def tearfree_total(name, per_frame, &body)
  rom = tearfree_rom(name, per_frame, &body)
  tf = Tempfile.new([name.downcase, ".gba"]); tf.binmode; rom.write(tf.path); tf.flush
  TFS << tf
  probe = GembaCore.open(tf.path)
  busy = 3.times.map { probe.busy_scanlines(settle: SETTLE) }.min
  stall = 3.times.map { probe.frame_cost(settle: SETTLE).dma_scanlines }.min
  probe.close
  busy + stall
end

# Per-ROW cost of a moving rectangle wide enough that its middle goes to the block-fill
# engine, starting at a column WRITTEN INTO the program so the parity is known. Two heights
# difference to one row; the once-per-rectangle preamble cancels.
#
# Measured on the moving shape itself, and that is the point. A moving rectangle steps its
# destination along where a fixed one rebuilds it, so a moving row assembled out of the
# fixed rectangle's weight paid for the address work twice.
def tearfree_engine_row(tag, col, w, per_frame, lo, hi)
  a = tearfree_total("#{tag}#{lo}", per_frame) { |b, _xv, yv| b.draw_rect_at col, yv, w, lo, :red }
  z = tearfree_total("#{tag}#{hi}", per_frame) { |b, _xv, yv| b.draw_rect_at col, yv, w, hi, :red }
  (z - a) / (per_frame * (hi - lo).to_f)
end

# Per-ROW cost of a rectangle: two heights of the same rectangle, over the extra rows.
# The once-per-rectangle preamble is identical in both, so it cancels.
def tearfree_row_cost(tag, per_frame, lo, hi, &draw)
  a = tearfree_busy("#{tag}#{lo}", per_frame) { |b, xv, yv| draw.call(b, xv, yv, lo) }
  z = tearfree_busy("#{tag}#{hi}", per_frame) { |b, xv, yv| draw.call(b, xv, yv, hi) }
  (z - a) / (per_frame * (hi - lo).to_f)
end

# The WHOLE cost of one rectangle, preamble included: more copies of the same rectangle
# at a fixed trip count. Subtracting the rows leaves what it costs before the first one.
def tearfree_rect_cost(tag, per_frame, &draw)
  a = tearfree_busy("#{tag}1", per_frame) { |b, xv, yv| draw.call(b, xv, yv) }
  z = tearfree_busy("#{tag}3", per_frame) { |b, xv, yv| 3.times { draw.call(b, xv, yv) } }
  (z - a) / (per_frame * 2.0)
end

# The stall the block-fill engine imposes on the tear-free screen while it copies. It
# moves 16 bits — two pixels — at a time here, so this is not the direct screen's rate.
def tearfree_fill_stall(h, per_frame)
  name = "tfs#{h}"
  rom = tearfree_rom(name, per_frame) { |b, _xv, _yv| b.fill_rect 0, 0, 240, h, :red }
  tf = Tempfile.new([name.downcase, ".gba"]); tf.binmode; rom.write(tf.path); tf.flush
  TFS << tf
  probe = GembaCore.open(tf.path)
  reads = 3.times.map { probe.frame_cost(settle: SETTLE).dma_scanlines }
  probe.close
  reads.min
end

# Per-frame cost of scrolling a background `per_frame` times — each scroll is a couple
# of register writes.
def scroll_busy(per_frame)
  rom = RubyGBA.build("scr#{per_frame}", code: "SC#{per_frame.to_s.rjust(2, '0')}", maker: "01", err: StringIO.new) do
    screen :tiled
    image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
    tiles :ts, "#" => :t
    bg = background :bg, tiles: :ts, map: Array.new(20, "#" * 30)
    game_loop { wait_vblank; repeat(per_frame) { bg.scroll_by 1, 0 } }
  end
  measure("scr#{per_frame}", rom)
end

measured = {}

# --- logic (op_* tiers) ---
measured[:op_step] = per_op("step", 500, 2, 8) { |b, _xv| b.add :x, 1 }
# What a pass of a `repeat` costs before its body does anything. Every weight around it
# is measured with the trip count held fixed, which cancels this — so it needs its own
# case or it is never measured at all.
measured[:loop_pass] = (loop_busy(900) - loop_busy(300)) / (900 - 300).to_f
# op_mul / op_div = op_step + the operator's extra cost over an add (a `set :y,
# (x <op> 100)` is a set plus the operator; differencing against `+` isolates it).
#
# WHICH OPERAND EACH ONE USES IS THE WHOLE POINT, because the lowering reduces some
# of them and a weight measured on a reduced op would price every op at the reduced
# cost — the model would then tell an author that dividing by 100 is free.
#
#   * 100         a real multiply. By a power of two it would be a shift.
#   / d           a real divide, and the ONLY kind left: a divisor written into the
#                 program is turned into a multiply at build time, so a divisor the
#                 game works out is now the only one that reaches the BIOS routine.
#   / 100         that reduction — a multiply by a reciprocal, its own tier.
#
# The reduced power-of-two case is priced as a plain step (see Pricing#op_weight).
measured[:op_mul] = measured[:op_step] +
                    (per_op("mul", 300, 2, 6) { |b, xv| b.set :y, (xv * 100) } -
                     per_op("addm", 300, 2, 6) { |b, xv| b.set :y, (xv + 2) })
# A divisor the game works out is the one case that still walks the answer a bit at a
# time, so it is TWO numbers: a fixed setup, and a step for every bit of the answer. The
# base is measured at an answer of no width at all, which is what op_div has always been
# (7 / 100 answers zero), so this number carries on from the one before it.
addd = per_op("addd", 60, 2, 6) { |b, xv| b.set :y, (xv + 2) }
measured[:op_div] = measured[:op_step] + (per_divide(0) - addd)
measured[:op_div_bit] = (per_divide(30) - per_divide(0)) / 30.0
# A divide by a number written into the program: no call, just a 64-bit multiply by a
# reciprocal worked out at build time and a couple of instructions to round it. A wrap
# (`%`) by such a number is built on this and costs somewhat more, and is priced here
# too — the same lumping of `/` and `%` the general tier already makes.
measured[:op_div_const] = measured[:op_step] +
                          (per_op("divc", 300, 2, 6) { |b, xv| b.set :y, (xv / 100) } -
                           per_op("addc", 300, 2, 6) { |b, xv| b.set :y, (xv + 2) })
# A fraction multiply is SMULL plus two instructions to shift the 64-bit product
# back down — dearer than a plain multiply, nowhere near a divide. Same differencing.
measured[:op_mul_fix] = measured[:op_step] +
                        (per_op("mulfix", 300, 2, 6) { |b, xv| b.set :y, xv.times_fraction(2, fraction_bits: 16) } -
                         per_op("addf", 300, 2, 6) { |b, xv| b.set :y, (xv + 2) })
# Dividing one number holding a fraction by another. The numerator no longer fits a
# register once it is widened, so this walks the whole width of the answer at a fixed
# price — the dearest arithmetic there is. Both operands are worked out by the game;
# with a numerator written down it folds into an ordinary division and is priced as one.
measured[:op_div_fix] = measured[:op_step] +
                        (per_op("divfix", 60, 2, 4) { |b, _xv, _dv, fv, gv| b.set :fout, (fv / gv) } -
                         per_op("addx", 60, 2, 4) { |b, xv| b.set :y, (xv + 2) })

# --- per-pixel drawing / sound ---
#
# A pixel comes in THREE shapes on the direct-color screen and they are not one price.
# plot_pixel is a pixel drawn ON ITS OWN: it works out a whole address and loads its
# color. Neither of the two below is that, and one of them is not close.
measured[:plot_pixel] = per_op("plot", 150, 4, 8) { |b, _xv| b.pixel 10, 10, :red }
# A pixel of a RUN of them, which is how a rectangle of a fixed size is drawn: the color
# is already held and each pixel is one address and one store. A font glyph's lit pixel
# is the same shape — it measures the same at every height on the screen — so ONE weight
# covers both. See #fill_rect_busy for why it is measured halfway down and not at the top.
measured[:plot_run_pixel] = (fill_rect_busy(32, 10, 20) - fill_rect_busy(4, 10, 20)) / ((32 - 4) * 10 * 20.0)
# The write itself costs the same wherever it lands. What differs is building the ADDRESS,
# and a bigger number takes another step to build — so a row far enough down the screen
# that its distance into the picture no longer fits in sixteen bits costs a step more, on
# every pixel. That is the bottom twenty rows: a status bar, a floor. Measured against the
# same fill higher up, where the address is one step shorter.
measured[:plot_run_address_step] =
  ((fill_rect_busy(32, 10, 20, DEEP_Y) - fill_rect_busy(4, 10, 20, DEEP_Y)) / ((32 - 4) * 10 * 20.0)) -
  measured[:plot_run_pixel]
# A lit pixel of a TRANSPARENT image — what a software sprite is made of. The position is
# worked out as the program runs, so every pixel is tested against the screen edges on
# its own before it is written, and it costs over twice what a pixel of a fixed-size
# rectangle does. Measured in red, which is a color that rides inside the instruction
# that writes it (see blit_wide_color below for the ones that do not).
blit_4x8 = blit_busy(4, 8, 2)
measured[:blit_pixel] = (blit_busy(32, 8, 2) - blit_4x8) / ((32 - 4) * 8 * 2.0)
# The extra for a pixel whose color does NOT fit inside that instruction, and so has to be
# built in a step of its own first. Drawing a pixel at a time means writing the color into
# every store, so this rides on every pixel of the art and is worth about a tenth of one:
# two pictures of the same shape can differ by that much on their colors alone. White is
# one of the colors that does not fit; red, green and blue all do.
measured[:blit_wide_color] =
  ((blit_busy(32, 8, 2, color: :white) - blit_busy(4, 8, 2, color: :white)) / ((32 - 4) * 8 * 2.0)) -
  measured[:blit_pixel]
# What one ROW of that costs beyond its own pixels: the row is tested against the top and
# the bottom of the screen once, and its place in the picture worked out. A row with
# nothing lit in it is skipped whole, so only lit rows pay this.
measured[:blit_row] = ((blit_busy(4, 32, 2) - blit_4x8) / ((32 - 8) * 2.0)) -
                      (4 * measured[:blit_pixel])
# What a blit costs BEFORE its first row: where it goes is worked out once, whatever it
# then draws. More COPIES of the same image at the same trip count gives the whole cost of
# one blit; taking off the rows and pixels priced above leaves the part that is fixed.
measured[:blit_start] = ((blit_busy(4, 8, 2, copies: 3) - blit_4x8) / ((3 - 1) * 2.0)) -
                        (8 * measured[:blit_row]) - (4 * 8 * measured[:blit_pixel])

# --- a LIVE digit: the walk over the chosen glyph, not the pixels it lights ---
#
# A line of text has its pixels settled while building. A live digit cannot: which of the
# ten shows is only known as the game runs, so the console walks the chosen glyph out of a
# table — testing EVERY cell of the digit's box, lit or not, and stamping each lit one.
#
# Three things cost, and three measurements separate them: two DIGITS of one font differ
# only in how many cells are lit, and two FONTS at the same digit differ in the size of the
# box as well.
digit_font = RubyGBA::Fonts.get(:default)
tiny_font = RubyGBA::Fonts.get(:tiny)
lit_spread = (digit_font.text_pixels("8") - digit_font.text_pixels("1")).to_f
d8 = per_digit_node(8, :default)
d1 = per_digit_node(1, :default)
t8 = per_digit_node(8, :tiny)

measured[:digit_pixel] = (d8 - d1) / lit_spread
measured[:digit_cell] =
  ((d8 - t8) - ((digit_font.text_pixels("8") - tiny_font.text_pixels("8")) * measured[:digit_pixel])) /
  (font_box(digit_font) - font_box(tiny_font)).to_f
# Whatever is left once the box and the lit cells are paid for is what starting one costs:
# finding the chosen glyph in the table before any of it is walked. (The walk's per-ROW
# work rides inside the per-cell figure — two fonts cannot separate a row from a cell, and
# fitted across both built-in fonts it lands within a hundredth on each.)
measured[:digit_start] = d8 - (font_box(digit_font) * measured[:digit_cell]) -
                         (digit_font.text_pixels("8") * measured[:digit_pixel])
# Stamping a lit cell on the TEAR-FREE screen, where a pixel is one byte sharing its
# sixteen bits with its neighbour and so is read, half changed and written back. The WALK
# is the same loop on both screens — measured, its start and its per-cell cost come out the
# same to within a hundredth — so this is the only part that moves.
measured[:tearfree_digit_pixel] =
  (per_digit_node(8, :default, tear_free: true) - per_digit_node(1, :default, tear_free: true)) / lit_spread

measured[:sound_write] = per_op("beep", 100, 2, 4) { |b, _xv| b.beep 440 } /
                         RubyGBA::IR::CostModel::BEEP_WRITES

# --- the software mixer: cost ~= base + slope*voices; per-sample weights ---
v1 = mixer_busy(1)
v8 = mixer_busy(8)
slope = (v8 - v1) / 7.0        # scanlines per added voice
base  = v1 - slope             # the voice-independent floor (0 voices)
measured[:mix_voice_sample] = slope / MIXER_SPF
measured[:mix_overhead_sample] = base / MIXER_SPF

# --- music: cost per active voice per frame (a 2-voice tune minus a 1-voice one
# isolates one voice; the per-song counter overhead cancels).
measured[:music_voice] = music_busy(2) - music_busy(1)

# --- DMA transfer per pixel: part of the stall the engine imposes while it copies. A wide
# fill's stall minus a narrow fill's stall at the SAME height cancels everything per-row
# (the row count is equal), leaving the per-pixel transfer over the extra pixels. The
# wall-clock probe sees this stall the busy count cannot.
#
# Measured FIRST because the start-up below is found by taking this out of a row's stall.
dma_pixel = (dma_stall(200, 100, 4) - dma_stall(40, 100, 4)) / ((200 - 40) * 100 * 4.0)

# --- STARTING one row's transfer. It costs on BOTH sides of the line the probe draws, and
# only one side used to be measured.
#
# The CPU writes a few registers to kick the engine off. That is busy time, on a fill two
# pixels wide so the transfer itself is negligible.
cpu_start = (dma_fill_busy(2, 40, 15) - dma_fill_busy(2, 8, 15)) / ((40 - 8) * 15.0)
# Then the engine takes a fixed moment of its own before the first pixel moves, and the CPU
# is STALLED through it — not executing — so the busy count cannot see it. Nor can the
# per-pixel weight: that is a marginal rate measured at a fixed row count, so it excludes
# the start-up by construction. It fell between the two and was charged by neither. Taking
# a row's own pixels back out of the stall per row leaves it, with nothing double-counted.
#
# It is about a ninth of the register writes: nothing on one wide row, real on a rectangle
# of forty short ones, where there is nothing to spread it over.
engine_start = ((dma_stall(8, 40, 4) - dma_stall(8, 20, 4)) / ((40 - 20) * 4.0)) - (8 * dma_pixel)
measured[:dma_setup] = cpu_start + engine_start
measured[:dma_pixel] = dma_pixel

# --- tiled per-frame upkeep: one OAM rewrite per presented sprite, a couple of register
# writes per background scroll.
measured[:obj_write] = (sprites_busy(64) - sprites_busy(8)) / (64 - 8).to_f
measured[:scroll_write] = (scroll_busy(40) - scroll_busy(8)) / (40 - 8).to_f

# --- what the DISPLAY is told to show, without redrawing a pixel. Both are a handful of
# register writes, and both are only safe in the vblank window, so both are drawing.
# `shake_screen` moves the camera every frame it runs, which is what makes the camera
# worth a weight rather than a shrug. The fade is measured at a level written into the
# program; a level the game works out costs the conversion on top (see Pricing#fade_cost).
measured[:camera_move] = per_op("cam", 100, 2, 6) { |b, _xv| b.camera 3, 5 }
measured[:fade_set] = per_op("fade", 100, 2, 6) { |b, _xv| b.fade :black, 50 }

# --- mirroring a saved variable back to save memory, on every change to it.
measured[:save_write] = (save_busy(60, 4, persist: true) - save_busy(60, 4, persist: false)) / (60 * 4.0)

# --- the tear-free screen's own drawing shapes. Every one of these is measured on that
# screen, because the same verb emits something else entirely on the direct-color one.
#
# A moving rectangle walks its rows, so a row is the address step plus its own pixels.
# Two widths of the same rectangle difference to the pixels, and one pixel wide (all
# edge, no pairs) gives the address step on its own.
row_w2 = tearfree_row_cost("tfr2", 20, 4, 20) { |b, xv, yv, h| b.draw_rect_at xv, yv, 2, h, :red }
row_w8 = tearfree_row_cost("tfr8", 20, 4, 20) { |b, xv, yv, h| b.draw_rect_at xv, yv, 8, h, :red }
row_w1 = tearfree_row_cost("tfr1", 20, 4, 20) { |b, xv, yv, h| b.draw_rect_at xv, yv, 1, h, :red }
measured[:tearfree_pair] = (row_w8 - row_w2) / 3.0 # 4 pairs against 1
measured[:tearfree_row] = row_w2 - measured[:tearfree_pair]
measured[:tearfree_edge] = row_w1 - measured[:tearfree_row]
# What a rectangle costs before its first row. A moving one pays much more of this than a
# fixed one: its position has to be worked out and its column's parity tested.
measured[:tearfree_moving_start] =
  tearfree_rect_cost("tfms", 20) { |b, xv, yv| b.draw_rect_at xv, yv, 8, 8, :red } -
  (8 * (measured[:tearfree_row] + (4 * measured[:tearfree_pair])))
# A fixed rectangle hands every row to the block-fill engine, so its rows measure what
# starting that engine costs here — the same shape dma_setup measures on the other screen.
fill_row = tearfree_row_cost("tff", 20, 4, 20) { |b, _xv, _yv, h| b.fill_rect 0, 0, 8, h, :red }
measured[:tearfree_rect_start] =
  tearfree_rect_cost("tffs", 20) { |b, _xv, _yv| b.fill_rect 0, 0, 8, 8, :red } - (8 * fill_row)
# The transfer itself, which the CPU never executes — it is stalled while the engine runs.
measured[:tearfree_fill_pixel] = (tearfree_fill_stall(80, 2) - tearfree_fill_stall(10, 2)) / (240 * 70 * 2.0)
# A row of a MOVING rectangle whose middle is wide enough to hand to the engine. It gets
# its own pair of weights rather than borrowing the fixed rectangle's, because the two are
# not the same work: a moving rectangle steps its destination along where a fixed one
# rebuilds it, and charging both the step and the rebuild paid for the address twice.
#
# An even column splices neither end of the row. An odd column with an even width splices
# BOTH — its near end shares a pair with the pixel before it, and its far end with the one
# after. Measured, the two ends differ a little (the near one costs about a third more),
# and one figure between them is what is charged; that shows only on an odd width, which
# is the one case with exactly one spliced end.
ENGINE_W = 40
engine_even = tearfree_engine_row("tfee", 40, ENGINE_W, 4, 10, 40)
engine_odd = tearfree_engine_row("tfeo", 41, ENGINE_W, 4, 10, 40)
measured[:tearfree_engine_row] = engine_even - (ENGINE_W * measured[:tearfree_fill_pixel])
measured[:tearfree_engine_edge] =
  ((engine_odd - ((ENGINE_W - 2) * measured[:tearfree_fill_pixel])) - measured[:tearfree_engine_row]) / 2.0
# One pixel drawn on its own, and one lit pixel of a font glyph. Both are read-modify-write
# here (a pixel shares its 16 bits with its neighbour); the lone one also has to find the
# hidden page's address, which a line of text holds for the whole line.
measured[:tearfree_pixel] =
  (tearfree_busy("tfp8", 150) { |b, _xv, _yv| 8.times { b.pixel 10, 10, :red } } -
   tearfree_busy("tfp4", 150) { |b, _xv, _yv| 4.times { b.pixel 10, 10, :red } }) / (150 * 4.0)
glyph_font = RubyGBA::Fonts.get(:default)
# Drawn HALFWAY DOWN the screen, on purpose. Forming the address of a pixel takes one
# instruction near the top of the screen and two below it, so text at y=0 is the one
# cheap case and everywhere else costs about a seventh more. Measuring at the top would
# under-charge every line of text that is not the first.
GLYPH_Y = 80
measured[:tearfree_glyph] =
  (tearfree_busy("tfg4", 30) { |b, _xv, _yv| b.draw_text "ABCD", 0, GLYPH_Y, :red } -
   tearfree_busy("tfg2", 30) { |b, _xv, _yv| b.draw_text "AB", 0, GLYPH_Y, :red }) /
  (30.0 * (glyph_font.text_pixels("ABCD") - glyph_font.text_pixels("AB")))

# --- per-pixel collision: a bigger overlap walks more pixels (size^2, fully overlapped
# opposite checkerboards force the full walk).
measured[:overlap_pixel] = (overlap_busy(16, 2) - overlap_busy(8, 2)) / (((16 * 16) - (8 * 8)) * 2.0)

# --- report + write the fixture ---
current = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS
puts format("%-20s %12s %12s %8s", "weight", "current", "measured", "ratio")
puts "-" * 56
measured.each do |k, v|
  cur = current[k]
  cur_s = cur ? format("%12.5f", cur) : format("%12s", "(new)")
  ratio_s = cur ? format("%7.2fx", v / cur) : format("%8s", "-")
  puts format("%-20s %s %12.5f %s", k, cur_s, v, ratio_s)
end

# 5 decimals so the smallest weight (dma_pixel, a per-pixel cost near 0.001) keeps
# enough significant figures — at 4 it would collapse to two.
rows = measured.map { |k, v| "        #{k}: #{format('%.5f', v)}," }
File.write(FIXTURE, <<~RUBY)
  # frozen_string_literal: true
  #
  # GENERATED by tools/calibrate_cost_model.rb — do not edit by hand.
  # Re-run that tool after changing the lowering of a priced op, and commit the diff.
  # Each value is scanlines per op, measured on the emulated GBA timing model via
  # gemba-core (emulated-cycle counts, not host wall-clock — the same on any machine).
  module RubyGBA
    module IR
      class CostModel
        MEASURED_WEIGHTS = {
  #{rows.join("\n")}
        }.freeze
      end
    end
  end
RUBY
puts
puts "wrote #{measured.size} weights to #{FIXTURE.sub("#{Dir.pwd}/", '')}"

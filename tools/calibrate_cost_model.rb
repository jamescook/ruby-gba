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
    enable_sound
    b = self
    game_loop do
      wait_vblank
      repeat(repeat_n) { body.call(b, xv) }
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
  b_lo = stable_busy("#{name}#{lo}", repeat_n) { |b, xv| lo.times { one.call(b, xv) } }
  b_hi = stable_busy("#{name}#{hi}", repeat_n) { |b, xv| hi.times { one.call(b, xv) } }
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

# One DMA fill of 2 x h, `per_frame` times a frame. Each row is a DMA whose fixed CPU
# setup (the register writes that kick it off) is dma_setup; adding rows isolates it.
# This is the CPU (busy) side — the register writes, not the transfer.
def dma_fill_busy(w, h, per_frame)
  stable_busy("dma#{w}x#{h}", per_frame) { |b, _xv| b.dma_fill_rect 0, 0, w, h, :red }
end

# The DMA-stall scanlines of a w x h fill done `per_frame` times a frame: the transfer
# time the DMA engine spends copying while the CPU is frozen. It never lands in the busy
# count (the CPU is stalled, not executing), but it is part of the frame's wall-clock
# work, which #frame_cost exposes as the difference between active and busy time.
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
# op_mul / op_div = op_step + the operator's extra cost over an add (a `set :y,
# (x <op> 100)` is a set plus the operator; differencing against `+` isolates it).
#
# The operand is 100 and not 2 on purpose. By a POWER OF TWO the lowering reduces
# both of these to shifts, so measuring with 2 would price every multiply and every
# divide at the reduced cost and the model would tell an author a divide by 100 is
# free. These weights are for the general case; the reduced one is priced as a plain
# step (see Pricing#op_weight), which is what the reduction actually costs.
measured[:op_mul] = measured[:op_step] +
                    (per_op("mul", 300, 2, 6) { |b, xv| b.set :y, (xv * 100) } -
                     per_op("addm", 300, 2, 6) { |b, xv| b.set :y, (xv + 2) })
measured[:op_div] = measured[:op_step] +
                    (per_op("div", 80, 2, 4) { |b, xv| b.set :y, (xv / 100) } -
                     per_op("addd", 80, 2, 4) { |b, xv| b.set :y, (xv + 2) })
# A fraction multiply is SMULL plus two instructions to shift the 64-bit product
# back down — dearer than a plain multiply, nowhere near a divide. Same differencing.
measured[:op_mul_fix] = measured[:op_step] +
                        (per_op("mulfix", 300, 2, 6) { |b, xv| b.set :y, xv.times_fraction(2, fraction_bits: 16) } -
                         per_op("addf", 300, 2, 6) { |b, xv| b.set :y, (xv + 2) })

# --- per-pixel drawing / sound ---
measured[:plot_pixel] = per_op("plot", 150, 4, 8) { |b, _xv| b.pixel 10, 10, :red }
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

# --- DMA fill per-row setup: the CPU register writes that start each row's DMA (a thin
# 2-wide fill, so the transfer itself is negligible). This is the busy (CPU) side.
measured[:dma_setup] = (dma_fill_busy(2, 40, 15) - dma_fill_busy(2, 8, 15)) / ((40 - 8) * 15.0)

# --- DMA transfer per pixel: the stall the DMA engine imposes while it copies. A wide
# fill's stall minus a narrow fill's stall at the SAME height cancels the per-row cost
# (row count is equal), leaving the per-pixel transfer over the extra pixels. The
# wall-clock probe sees this stall the busy count cannot.
measured[:dma_pixel] = (dma_stall(200, 100, 4) - dma_stall(40, 100, 4)) / ((200 - 40) * 100 * 4.0)

# --- tiled per-frame upkeep: one OAM rewrite per presented sprite, a couple of register
# writes per background scroll.
measured[:obj_write] = (sprites_busy(64) - sprites_busy(8)) / (64 - 8).to_f
measured[:scroll_write] = (scroll_busy(40) - scroll_busy(8)) / (40 - 8).to_f

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

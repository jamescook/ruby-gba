# frozen_string_literal: true

# Calibrate the cost model's per-op weights against real hardware.
#
# Each weight is the cost, in scanlines, the model charges for one op. We measure
# the real thing: build a ROM whose per-frame loop does an op a known number of
# times, run it on the emulator (gemba-core), and read the CPU cycles it actually
# burns per frame (Probe#busy_scanlines). Differencing two ROMs that differ only
# in the op under test cancels the fixed per-frame overhead (the game loop, the
# vblank wait, the repeat counter), leaving the op's marginal cost.
#
# The measurement is only valid while a frame's work fits inside a frame (~228
# scanlines) — past that busy_scanlines caps and wobbles — so the sizes below are
# kept well under that, and #stable_busy re-reads to confirm.
#
# Usage: ruby tools/calibrate_cost_model.rb

require_relative "../lib/ruby_gba"
require_relative "../gemba-core/lib/gemba_core"
require "tempfile"
require "stringio"

SETTLE = 8
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
  tf = Tempfile.new([name.downcase, ".gba"]); tf.binmode; rom.write(tf.path); tf.flush
  TFS << tf
  probe = GembaCore.open(tf.path)
  reads = 3.times.map { probe.busy_scanlines(settle: SETTLE) }
  probe.close
  warn "  ! #{name}: unstable reads #{reads.map { |r| r.round(1) }} (frame overflow?)" if reads.max - reads.min > 1.0
  warn "  ! #{name}: #{reads.first.round(1)} scanlines — near the 228 frame ceiling" if reads.min > 200
  reads.min
end

# Marginal cost per op: (busy with `hi` copies of the op each iteration) minus
# (busy with `lo`), over the extra ops — the op's own cost, overhead cancelled.
def per_op(name, repeat_n, lo, hi, &one)
  b_lo = stable_busy("#{name}#{lo}", repeat_n) { |b, xv| lo.times { one.call(b, xv) } }
  b_hi = stable_busy("#{name}#{hi}", repeat_n) { |b, xv| hi.times { one.call(b, xv) } }
  (b_hi - b_lo) / (repeat_n * (hi - lo).to_f)
end

W = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS
r = {}

r[:op_step] = per_op("step", 500, 2, 8) { |b, _xv| b.add :x, 1 }

# op_mul / op_div = op_step + the operator's extra cost over an add (a `set :y,
# (x <op> 2)` is a set plus the operator; differencing against `+` isolates it).
r[:op_mul] = r[:op_step] +
             (per_op("mul", 300, 2, 6) { |b, xv| b.set :y, (xv * 2) } -
              per_op("addm", 300, 2, 6) { |b, xv| b.set :y, (xv + 2) })
r[:op_div] = r[:op_step] +
             (per_op("div", 300, 2, 6) { |b, xv| b.set :y, (xv / 2) } -
              per_op("addd", 300, 2, 6) { |b, xv| b.set :y, (xv + 2) })

r[:plot_pixel] = per_op("plot", 150, 4, 8) { |b, _xv| b.pixel 10, 10, :red }

# dma_pixel: extra cost per pixel of a fill row (widen the rect, same row count).
# dma_setup: the fixed per-row cost, backed out of the narrow fill vs a baseline.
narrow = stable_busy("filln", 40) { |b, _xv| b.fill_rect 0, 0, 2, 1, :red }
wide   = stable_busy("fillw", 40) { |b, _xv| b.fill_rect 0, 0, 120, 1, :red }
base   = stable_busy("base",  40) { |_b, _xv| }
r[:dma_pixel] = (wide - narrow) / (40 * (120 - 2).to_f)
r[:dma_setup] = ((narrow - base) / 40.0) - 2 * r[:dma_pixel]

r[:sound_write] = per_op("beep", 100, 2, 4) { |b, _xv| b.beep 440 } /
                  RubyGBA::IR::CostModel::BEEP_WRITES

puts format("%-14s %12s %12s %8s", "weight", "current", "measured", "ratio")
puts "-" * 50
%i[op_step op_mul op_div plot_pixel dma_setup dma_pixel sound_write].each do |k|
  puts format("%-14s %12.5f %12.5f %7.2fx", k, W[k], r[k], r[k] / W[k])
end

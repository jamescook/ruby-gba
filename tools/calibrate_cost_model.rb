# frozen_string_literal: true

# Calibrate the cost model's per-op weights against real hardware, and WRITE the
# result as a source-controlled Ruby fixture (lib/ruby_gba/ir/measured_weights.rb)
# that the cost model loads — no hand-copying, no JSON/YAML.
#
# Each weight is the cost, in scanlines, the model charges for one op. We measure
# the real thing: build a ROM whose per-frame loop does an op a known number of
# times, run it on the emulator (gemba-core), and read the CPU cycles it actually
# burns per frame (Probe#busy_scanlines). Differencing two ROMs that differ only
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

measured = {}

# --- logic (op_* tiers) ---
measured[:op_step] = per_op("step", 500, 2, 8) { |b, _xv| b.add :x, 1 }
# op_mul / op_div = op_step + the operator's extra cost over an add (a `set :y,
# (x <op> 2)` is a set plus the operator; differencing against `+` isolates it).
measured[:op_mul] = measured[:op_step] +
                    (per_op("mul", 300, 2, 6) { |b, xv| b.set :y, (xv * 2) } -
                     per_op("addm", 300, 2, 6) { |b, xv| b.set :y, (xv + 2) })
measured[:op_div] = measured[:op_step] +
                    (per_op("div", 80, 2, 4) { |b, xv| b.set :y, (xv / 2) } -
                     per_op("addd", 80, 2, 4) { |b, xv| b.set :y, (xv + 2) })

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

# --- report + write the fixture ---
current = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS
puts format("%-20s %12s %12s %8s", "weight", "current", "measured", "ratio")
puts "-" * 56
measured.each do |k, v|
  cur = current[k]
  puts format("%-20s %12.5f %12.5f %7.2fx", k, cur, v, cur ? v / cur : Float::NAN)
end

rows = measured.map { |k, v| "        #{k}: #{format('%.4f', v)}," }
File.write(FIXTURE, <<~RUBY)
  # frozen_string_literal: true
  #
  # GENERATED by tools/calibrate_cost_model.rb — do not edit by hand.
  # Re-run that tool after changing the lowering of a priced op, and commit the diff.
  # Each value is scanlines per op, measured on real hardware via gemba-core.
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

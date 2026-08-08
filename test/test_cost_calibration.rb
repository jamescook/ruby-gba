# frozen_string_literal: true

require "test_helper"

# The keep-honest check: the draw-cost model's weights were measured on hardware,
# and this test makes sure they stay true. It builds a representative frame (a mix
# of DMA fills and text), asks the model to PREDICT its cost in scanlines, and
# MEASURES the real cost on gemba (via the scanline probe). If a change to the
# lowering makes an op cheaper or dearer, the measured cost drifts from the model's
# prediction and this fails — a signal to re-measure and re-calibrate. The tolerance
# is generous: the measurement is coarse (whole scanlines) and the model is a
# deliberate approximation, so this guards against real drift, not small noise.
class TestCostCalibration < Minitest::Test

  CostModel = RubyGBA::IR::CostModel

  # A representative frame: a stack of DMA fills plus a line of text — the two cost
  # regimes (per-row DMA, and plotted glyphs) in one frame. Returns the program and
  # the backend that lowered it (for the variable address).
  def sampled_frame
    builder = Builder.new
    builder.extend(RubyGBA::Builder::Debug)
    builder.instance_eval do
      screen :bitmap
      wait_vblank
      30.times { |i| dma_fill_rect 0, (i * 4) % 150, 220, 2, :red } # 30 DMA fills
      draw_text "SCORE 1234", 8, 8, :white                          # 10 glyphs, plotted
      set :sample, read_scanline
      halt
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_the_model_predicts_the_measured_scanlines
    program = sampled_frame
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "CALCHK", code: "BCAL", maker: "01")

    v = assert_gemba_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    measured = v.var(:sample) - 160 # scanlines of vblank the drawing consumed
    predicted = CostModel.new.frame_cost(program)

    assert_operator measured, :>, 0, "the workload should take measurable time"
    assert_in_delta predicted, measured, (predicted * 0.25) + 2,
                    "model predicted ~#{predicted.round(1)} scanlines, hardware measured #{measured} — " \
                    "the cost weights have drifted from reality; re-measure and re-calibrate"
  end

  # The same check for a timer's tick handler, which is nowhere in the frame the test above
  # measures: its body runs off the timer, not the loop. A fast timer is most of a frame, so
  # a drifted weight here would quietly hide that whole frame — which is exactly what this
  # cost being missing did before it was priced.
  #
  # Measured by DIFFERENCE against the same program with no timer, so only the ticks are
  # left; the timer's own rate is what the estimate has to get right, and it is written
  # nowhere near the handler.
  TICK_HZ = 4000

  def ticking_frame(with_timer:)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      n = var :n, 0
      timer(:beat, per_second: TICK_HZ).on_tick { n.add 1 } if with_timer
      game_loop { }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_the_model_predicts_what_a_timers_ticks_measure
    with = ticking_frame(with_timer: true)
    without = ticking_frame(with_timer: false)
    backend = GBA.new
    backend.lower(with)
    moved = backend.iwram_report[:funcs].include?(RubyGBA::IR::Backends::GBA::Placement::IRQ_ROUTINE)
    predicted = CostModel.new(fast_interrupts: moved).tick_cost(with)

    measured = busy_scanlines(with) - busy_scanlines(without)
    assert_operator measured, :>, 1, "4000 ticks a second is measurable work"
    assert_in_delta predicted, measured, (predicted * 0.25) + 1,
                    "model predicted ~#{predicted.round(1)} scanlines for #{TICK_HZ}Hz of ticks, " \
                    "hardware measured #{measured.round(1)} — re-measure tick_interrupt"
  end

  def busy_scanlines(program)
    rom = ROM.assemble(GBA.new.lower(program), title: "TICKCAL", code: "BTKC", maker: "01")
    require_gemba_core!
    Tempfile.create(["tick", ".gba"]) do |file|
      file.binmode
      rom.write(file.path)
      probe = GembaCore.open(file.path)
      reading = 3.times.map { probe.busy_scanlines(settle: 12) }.min
      probe.close
      return reading
    end
  end
end

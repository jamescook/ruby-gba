# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The keep-honest check: the draw-cost model's weights were measured on hardware,
# and this test makes sure they stay true. It builds a representative frame (a mix
# of DMA fills and text), asks the model to PREDICT its cost in scanlines, and
# MEASURES the real cost on gemba (via the scanline probe). If a change to the
# lowering makes an op cheaper or dearer, the measured cost drifts from the model's
# prediction and this fails — a signal to re-measure and re-calibrate. The tolerance
# is generous: the measurement is coarse (whole scanlines) and the model is a
# deliberate approximation, so this guards against real drift, not small noise.
class TestCostCalibration < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
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
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# read_scanline: the hardware read the draw-cost timing probe is built on. The
# console draws scanline by scanline; VCOUNT reports the current one; the vertical
# blank (the safe window to draw) is scanlines 160..227. Sample the scanline right
# after a frame's drawing and (scanline - 160) is how much of that window the
# drawing used. This asserts the measurement is real on gemba — it starts at the top
# of vblank and climbs as the frame does more drawing — and that the headless
# interpreter refuses it (it has no real timing). It's built through the non-public
# Builder::Debug mixin as a regular IR node, not raw assembly.
class TestScanlineProbe < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Build = RubyGBA::IR::Build

  # Wait for vblank, do +fills+ full-width fills (drawing work), then sample the
  # scanline and halt. Returns the sampled scanline read back from IWRAM on gemba.
  def scanline_after(fills)
    builder = Builder.new
    builder.extend(RubyGBA::Builder::Debug)
    builder.instance_eval do
      screen :bitmap
      wait_vblank
      fills.times { |i| dma_fill_rect 0, i % 100, 240, 1, :red }
      set :sample, read_scanline
      halt
    end
    builder.emit_pending_functions
    backend = GBA.new
    rom = ROM.assemble(backend.lower(builder.program), title: "SCANL", code: "BSCN", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    v.var(:sample)
  end

  def test_with_no_drawing_the_sample_sits_at_the_top_of_vblank
    s = scanline_after(0)
    assert_includes 160..164, s, "with no drawing the sample should sit right at the start of vblank (160)"
  end

  def test_more_drawing_uses_more_of_the_vblank_window
    none = scanline_after(0)
    some = scanline_after(20)
    lots = scanline_after(60)
    assert_operator some, :>, none, "some drawing should push the scanline past the vblank start"
    assert_operator lots, :>, some, "more drawing should use more of the window"
    assert_operator lots, :<=, 227, "this workload should still finish within vblank"
  end

  # ---- the headless interpreter has no real timing, so it refuses it ----

  def test_the_interpreter_refuses_read_scanline
    err = assert_raises(Reference::ProgramError) do
      Reference.new.run(Build.program(Build.set(:x, Build.read_scanline)))
    end
    assert_match(/hardware-only/, err.message)
  end

  def test_read_scanline_is_not_a_public_dsl_verb
    # A game developer never sees it — a plain Builder does not respond to it; only
    # a builder that opts into Builder::Debug does.
    refute_respond_to Builder.new, :read_scanline
    assert_respond_to Builder.new.extend(RubyGBA::Builder::Debug), :read_scanline
  end
end

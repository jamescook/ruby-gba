# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The Analyzer measures a built ROM's real per-frame CPU cost on the emulator — the
# measured counterpart to the static cost estimate. These run real ROMs through gemba
# and read the busy scanlines a frame burns.
class TestAnalyzer < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Analyzer = RubyGBA::Analyzer

  # Build a program, write it to a temp .gba, and measure it.
  def measure(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(b.program), title: "ANLZ", code: "BANL", maker: "01")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.gba")
      rom.write(path)
      return RubyGBA::Analyzer.measure(path)
    end
  end

  def test_a_light_loop_measures_a_small_per_frame_cost
    result = measure do
      screen :bitmap
      game_loop { wait_vblank }
    end
    assert_operator result.scanlines, :>, 0, "the CPU does some work each frame"
    refute result.saturated?, "a near-empty loop is nowhere near the 228-scanline ceiling"
    assert_operator result.percent, :<, 100
  end

  # The Result's read of its own number: near the frame ceiling is "saturated" (the
  # measurement can't count past a frame's worth of work), below it is a plain percent.
  def test_result_reads_saturation_and_percent
    refute Analyzer::Result.new(scanlines: 50.0).saturated?
    assert Analyzer::Result.new(scanlines: 220.0).saturated?
    assert_equal 50, Analyzer::Result.new(scanlines: 114.0).percent
  end
end

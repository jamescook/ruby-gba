# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The per-pixel collision primitive (pixels_overlap): given two posed sprites and where
# they sit, is any pixel drawn (non-transparent) in both at once? This is the
# shape-accurate half of `overlaps?`. Tested at the IR level (hand-built trees) because
# it's the lowering under test, not the DSL surface — on the interpreter oracle AND on
# real hardware, since a feature isn't done until both backends agree.
class TestPixelsOverlap < Minitest::Test
  include RubyGBA::IR::Build
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  TRANSPARENT = 0x8000
  SOLID = 0x1F

  # A 4x4 image whose left two columns are drawn and right two are see-through.
  def left_half
    (Array.new(4) { [SOLID, SOLID, TRANSPARENT, TRANSPARENT] }).flatten.pack("v*")
  end

  # a's solid columns are x0..1; b's solid columns are bx..bx+1. They share a solid
  # column only for bx in {0, 1}.
  def touch_node(bx)
    pixels_overlap(a_poses: [:a], a_pose: int(0), a_x: int(0), a_y: int(0),
                   b_poses: [:b], b_pose: int(0), b_x: int(bx), b_y: int(0))
  end

  def images
    [bitmap(:a, width: 4, height: 4, pixels: left_half, transparent: TRANSPARENT),
     bitmap(:b, width: 4, height: 4, pixels: left_half, transparent: TRANSPARENT)]
  end

  # --- interpreter oracle: exact per-pixel truth ---

  def interpreter_hit(bx)
    prog = program(screen(:bitmap), *images, set(:hit, int(0)),
                   if_(touch_node(bx), set(:hit, int(1))), halt)
    Ruby.new.run(prog)[:hit]
  end

  def test_overlap_is_true_only_where_solid_pixels_meet
    assert_equal 1, interpreter_hit(0), "fully aligned: solid columns coincide"
    assert_equal 1, interpreter_hit(1), "b shifted 1: b's left column meets a's right solid column"
    assert_equal 0, interpreter_hit(2), "b shifted 2: solid columns no longer meet"
    assert_equal 0, interpreter_hit(3), "boxes still touch, but the drawn pixels are apart"
  end

  # --- hardware: the same answer, computed by the ARM routine ---

  # Draw a red marker only when the pixels overlap, so a real hit is visible on screen.
  def rom_for(bx)
    prog = program(screen(:bitmap), clear_screen(Color.resolve(:black)), *images,
                   if_(touch_node(bx), fill_rect(100, 100, 4, 4, Color.resolve(:red))), halt)
    ROM.assemble(GBA.new.lower(prog), title: "PIXHIT", code: "BPXO", maker: "01")
  end

  def test_the_console_agrees_on_a_hit
    v = assert_gemba_loads_rom(rom_for(1), frames: 2) # b@1 overlaps
    assert v.red?(101, 101), "the console drew the hit marker, got 0x#{format('%04X', v.pixel_gba(101, 101))}"
  end

  def test_the_console_agrees_on_a_miss
    v = assert_gemba_loads_rom(rom_for(3), frames: 2) # b@3: no solid overlap
    refute v.red?(101, 101), "no hit marker — the drawn pixels don't meet"
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Edge clipping for blit: a bitmap pushed partway off a screen edge must draw
# only its on-screen part — no pixels past the framebuffer, and (on the console)
# no per-row DMA overrun that wraps garbage onto the neighbouring line.
#
# The Ruby interpreter is the reference: it already clips per pixel (set_pixel
# drops off-screen writes). Every case runs on BOTH backends and asserts the
# SAME visible pixels, so the console's clipped output has to match the oracle
# exactly. The programs are built straight from IR::Build (no DSL sugar) so the
# clip math is what's under test, not the surface.
class TestBlitClipping < Minitest::Test
  include RubyGBA::IR::Build
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  Color = RubyGBA::Color

  BG = :yellow # a background distinct from the bitmap's four colours

  # Four distinct colours, so a wrong source offset or transfer count shows up as
  # the wrong colour landing (not merely "something drawn").
  FOUR = [:red, :green, :blue, :white].map { |c| Color.resolve(c) }.freeze

  # A 4-wide, 1-tall opaque strip: red, green, blue, white left-to-right.
  def strip_h(name)
    bitmap(name, width: 4, height: 1, pixels: FOUR.pack("v*"))
  end

  # A 1-wide, 4-tall opaque strip: red, green, blue, white top-to-bottom.
  def strip_v(name)
    bitmap(name, width: 1, height: 4, pixels: FOUR.pack("v*"))
  end

  # A 4x4 opaque block whose rows are red / green / blue / white (each row one
  # colour), so a corner clip reveals which rows survived.
  def block(name)
    rows = FOUR.flat_map { |c| [c, c, c, c] }
    bitmap(name, width: 4, height: 4, pixels: rows.pack("v*"))
  end

  # Run +stmts+ (a blit sandwiched between screen/clear/halt) on both backends
  # and assert each [x, y, colour] expectation holds on each. A nil colour means
  # "background here" — i.e. clipped, nothing drawn.
  def assert_same_pixels(defn, blit_stmt, expectations)
    prog = program(screen(:bitmap), clear_screen(BG), defn, blit_stmt, halt)

    screen = Ruby.new.run(prog).screen
    expectations.each do |x, y, color|
      want = Color.resolve(color || BG)
      assert_equal want, screen.pixel(x, y),
                   "interpreter: (#{x}, #{y}) should be #{color || 'background'}"
    end

    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "CLIPTEST", code: "BCLP", maker: "01")
    v = assert_gemba_loads_rom(rom)
    expectations.each do |x, y, color|
      assert v.pixel_is?(x, y, color || BG),
             "console: (#{x}, #{y}) should be #{color || 'background'}, got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end

  # --- horizontal clip: adjusts DMA source, destination, and count ------------

  def test_clips_off_the_left_edge
    # The strip's left two columns (red, green) hang off; blue/white show at x=0,1.
    # A per-row DMA that ignored the clip would start two pixels early and wrap
    # red/green onto the end of the previous row — so those must be background.
    assert_same_pixels(
      strip_h(:sh), blit(:sh, -2, 40),
      [[0, 40, :blue], [1, 40, :white], [2, 40, nil],
       [238, 39, nil], [239, 39, nil]], # no wrap onto the previous row
    )
  end

  def test_clips_off_the_right_edge
    # x = 238: red/green show at 238/239; blue/white would land at 240/241 (off).
    assert_same_pixels(
      strip_h(:sh), blit(:sh, 238, 40),
      [[238, 40, :red], [239, 40, :green],
       [0, 41, nil], [1, 41, nil]], # count trimmed to 2 — no spill onto the next row
    )
  end

  # --- vertical clip: whole off-screen rows are skipped -----------------------

  def test_clips_off_the_top_edge
    # y = -2: rows red/green are above the screen; blue/white show at y=0,1.
    assert_same_pixels(
      strip_v(:sv), blit(:sv, 60, -2),
      [[60, 0, :blue], [60, 1, :white], [60, 2, nil]],
    )
  end

  def test_clips_off_the_bottom_edge
    # y = 158: rows red/green show at 158/159; blue/white are below the screen.
    assert_same_pixels(
      strip_v(:sv), blit(:sv, 60, 158),
      [[60, 158, :red], [60, 159, :green]],
    )
  end

  # --- corner + negative coordinates: both clips compose ----------------------

  def test_clips_off_the_top_left_corner
    # (-2, -2): only the block's bottom-right 2x2 is on-screen — rows blue/white.
    assert_same_pixels(
      block(:bq), blit(:bq, -2, -2),
      [[0, 0, :blue], [1, 0, :blue], [0, 1, :white], [1, 1, :white],
       [2, 0, nil], [0, 2, nil]],
    )
  end

  def test_a_fully_off_screen_blit_draws_nothing
    # Entirely above the screen: nothing drawn, nothing corrupted.
    assert_same_pixels(
      strip_h(:sh), blit(:sh, 40, -8),
      [[40, 0, nil], [41, 0, nil], [42, 0, nil]],
    )
  end

  # --- transparency clips per pixel too ---------------------------------------

  def test_transparent_blit_clips_off_the_left_edge
    # A transparent bitmap is drawn pixel-by-pixel; the clip must drop the pixels
    # that fall off-screen while still letting the background show through the
    # transparent ones that remain.
    clear = 0x8000 # the transparent marker (bit 15, no real colour uses it)
    pixels = [Color.resolve(:red), Color.resolve(:green), Color.resolve(:blue), clear]
    defn = bitmap(:tdot, width: 4, height: 1, pixels: pixels.pack("v*"), transparent: clear)
    # x = -1: red (col0) is a lit pixel pushed off the left edge — it must be
    # clipped, not wrapped onto the end of the previous row. green (col1) lands at
    # x=0, blue (col2) at x=1, and the transparent col3 shows background at x=2.
    assert_same_pixels(
      defn, blit(:tdot, -1, 70),
      [[0, 70, :green], [1, 70, :blue], [2, 70, nil], [239, 69, nil]],
    )
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Double-buffered (Mode 4) bitmap display: the tear-proof screen. Drawing goes to
# a hidden page shown all at once, and the framework builds a color palette from
# the names used so the developer never touches "indexed color". The observable
# promise is: the SAME draw code renders the SAME picture as direct-color mode —
# only tearing is gone.
#
# The Ruby interpreter is the oracle (double buffering is invisible to it — it
# reads the settled frame). Every render case runs on BOTH backends and asserts
# the same visible pixels, so the console's Mode 4 output (indices resolved
# through the auto-built palette, presented after a page flip) has to match.
# Programs are built straight from IR::Build so the lowering is what's under test.
class TestBufferedMode4 < Minitest::Test
  include RubyGBA::IR::Build
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  Color = RubyGBA::Color

  # A blue field with three diagnostic squares in distinct colors at known spots —
  # a wrong palette index or a mis-computed page address lands the wrong color, so
  # each assertion pins a specific color at a specific pixel. Squares sit on even
  # columns (Mode 4 fills two pixels at a time). One wait_vblank presents the page.
  def diagnostic_program
    program(
      display(:bitmap, buffered: true),
      clear_screen(:blue),
      dma_fill_rect(0, 0, 8, 8, :red),      # top-left
      dma_fill_rect(232, 8, 8, 8, :green),  # top-right area
      draw_rect_at(100, 80, 8, 8, :white),  # a run-time-positioned square, center-ish
      wait_vblank,                          # flip: show the page we just drew
      halt,
    )
  end

  # x, y, expected color — the same checks both backends must satisfy.
  CHECKS = [
    [4, 4, :red],
    [235, 11, :green],
    [103, 83, :white],
    [120, 120, :blue], # background between the squares
    [50, 50, :blue],
  ].freeze

  def test_interpreter_renders_the_buffered_frame
    i = Ruby.new.run(diagnostic_program)
    assert i.buffered, "the interpreter should record the buffered flag"
    CHECKS.each do |x, y, color|
      assert_equal Color.resolve(color), i.screen.pixel(x, y),
                   "interpreter: (#{x}, #{y}) should be #{color}"
    end
  end

  # The hardware proof: gemba boots the ROM and renders Mode 4 for real — each
  # pixel's index looked up in the palette we uploaded, the drawn page presented
  # by the flip. The colors must come out as named.
  def test_gemba_renders_the_buffered_frame_through_the_palette
    rom = RubyGBA::ROM.assemble(GBA.new.lower(diagnostic_program),
                                title: "BUF4", code: "BBF4", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    CHECKS.each do |x, y, color|
      assert v.pixel_is?(x, y, color),
             "console: (#{x}, #{y}) should be #{color}, got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end

  # The page actually flips: two frames drawing different colors show the LATEST,
  # not a stale page. A loop that fills the whole screen red on even frames and
  # green on odd frames must, after several frames, show one solid color (never a
  # half-and-half mix), and it must be the color drawn on the frame that was
  # presented last.
  def test_the_displayed_page_reflects_the_latest_drawn_frame
    # tick toggles 0/1 each frame; even frames clear red, odd clear green.
    branch = if_(binop(:==, var_ref(:tick), int(0)), clear_screen(:red), set(:tick, 1))
    branch[:else] = else_(clear_screen(:green), set(:tick, 0))
    prog = program(
      display(:bitmap, buffered: true),
      set(:tick, 0),
      loop_(branch, wait_vblank),
    )

    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "FLIP", code: "BFLP", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 8)
    # Whatever's shown, it's ONE solid color across the screen — no torn/mixed page.
    corner = v.pixel_gba(4, 4)
    assert_includes [Color.resolve(:red), Color.resolve(:green)], corner,
                    "expected a solid red or green screen, got 0x#{format('%04X', corner)}"
    assert_equal corner, v.pixel_gba(235, 155), "the whole screen should be one color (page fully drawn)"
  end

  # --- the palette limit surfaces as a friendly build error, not a black screen ---

  def test_too_many_colors_in_a_buffered_program_is_a_friendly_build_error
    many = (1..300).map { |c| dma_fill_rect(0, 0, 2, 2, c) } # 300 distinct raw colors
    prog = program(display(:bitmap, buffered: true), *many, halt)
    err = assert_raises(RubyGBA::IR::Palette::Overflow) { GBA.new.lower(prog) }
    assert_match(/300/, err.message)
    assert_match(/display :bitmap/, err.message) # points at the direct-color escape hatch
  end

  # --- the pixel-granular verbs aren't lowered in Mode 4 yet: a clear error ---

  def test_pixel_in_buffered_mode_is_a_friendly_not_yet_error
    prog = program(display(:bitmap, buffered: true), pixel(10, 10, :red), halt)
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/pixel/, err.message)
    assert_match(/dma_fill_rect|rectangle fills/, err.message) # names the supported path
  end

  def test_draw_text_in_buffered_mode_is_a_friendly_not_yet_error
    prog = program(display(:bitmap, buffered: true), draw_text("HI", 10, 10, :white), halt)
    assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
  end

  # --- Mode 4 fills move two pixels at a time: an odd start column is caught ---

  def test_an_odd_start_column_is_a_friendly_error
    prog = program(display(:bitmap, buffered: true), dma_fill_rect(3, 0, 8, 8, :red), halt)
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/even/, err.message)
  end

  # --- the DSL surface: buffered: is only for :bitmap ---

  def test_buffered_is_rejected_for_non_bitmap_modes
    b = RubyGBA::Builder.new
    err = assert_raises(ArgumentError) { b.display(:tiled, buffered: true) }
    assert_match(/buffered/, err.message)
  end
end

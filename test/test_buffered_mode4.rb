# frozen_string_literal: true

require "test_helper"

# Double-buffered (Mode 4) bitmap display: the tear-proof screen. Drawing goes to
# a hidden page shown all at once, and the framework builds a color palette from
# the names used so the developer never touches "indexed color". The observable
# promise is: the SAME draw code renders the SAME picture as direct-color mode —
# only tearing is gone.
#
# The reference interpreter is the oracle (double buffering is invisible to it — it
# reads the settled frame). Every render case runs on BOTH backends and asserts
# the same visible pixels, so the console's Mode 4 output (indices resolved
# through the auto-built palette, presented after a page flip) has to match.
# Programs are built straight from IR::Build so the lowering is what's under test.
class TestBufferedMode4 < Minitest::Test
  include RubyGBA::IR::Build

  # A blue field with three diagnostic squares in distinct colors at known spots —
  # a wrong palette index or a mis-computed page address lands the wrong color, so
  # each assertion pins a specific color at a specific pixel. Squares sit on even
  # columns (Mode 4 fills two pixels at a time). One wait_vblank presents the page.
  def diagnostic_program
    program(
      screen(:bitmap, buffered: true),
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
    i = Reference.new.run(diagnostic_program)
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
    rom = assemble_rom(diagnostic_program, name: "BUF4")
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
      screen(:bitmap, buffered: true),
      set(:tick, 0),
      loop_(branch, wait_vblank),
    )

    rom = assemble_rom(prog, name: "FLIP")
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
    prog = program(screen(:bitmap, buffered: true), *many, halt)
    err = assert_raises(RubyGBA::IR::Palette::Overflow) { GBA.new.lower(prog) }
    assert_match(/300/, err.message)
    assert_match(/screen :bitmap/, err.message) # points at the direct-color escape hatch
  end

  # --- pixel + draw_text on the indexed screen (read-modify-write) ---

  # Single pixels and text render in buffered mode, and — the crux of the
  # read-modify-write — writing one pixel must NOT disturb the pixel it shares a
  # 16-bit unit with. An even column writes the low byte, an odd column the high
  # byte; each leaves its neighbor's background intact.
  def test_pixel_and_text_render_and_preserve_the_paired_pixel
    prog = program(
      screen(:bitmap, buffered: true),
      clear_screen(:blue),
      pixel(10, 10, :red),    # even column -> low byte of its 16-bit unit
      pixel(11, 20, :green),  # odd column  -> high byte
      set(:px, 100), set(:py, 100),
      pixel(:px, :py, :yellow), # run-time coordinates
      draw_text("A", 40, 40, :white),
      wait_vblank,
      halt,
    )

    # Interpreter oracle: the colors land where expected.
    i = Reference.new.run(prog)
    assert_equal Color.resolve(:red), i.screen.pixel(10, 10)
    assert_equal Color.resolve(:green), i.screen.pixel(11, 20)
    assert_equal Color.resolve(:yellow), i.screen.pixel(100, 100)

    # Hardware: the RMW writes the right byte and preserves its pair.
    rom = assemble_rom(prog, name: "DTX")
    v = assert_gemba_loads_rom(rom, frames: 4)
    assert v.pixel_is?(10, 10, :red),    "even-column pixel, got 0x#{format('%04X', v.pixel_gba(10, 10))}"
    assert v.pixel_is?(11, 20, :green),  "odd-column pixel, got 0x#{format('%04X', v.pixel_gba(11, 20))}"
    assert v.pixel_is?(100, 100, :yellow), "runtime-coordinate pixel, got 0x#{format('%04X', v.pixel_gba(100, 100))}"
    # The paired pixel in each 16-bit unit must stay the blue background.
    assert v.pixel_is?(11, 10, :blue), "the red pixel's neighbor must stay blue (RMW preserved it)"
    assert v.pixel_is?(10, 20, :blue), "the green pixel's neighbor must stay blue"
    assert v.pixel_is?(101, 100, :blue), "the yellow pixel's neighbor must stay blue"
    # And the glyph drew white somewhere in its 5x7 band.
    drew_glyph = (40..44).any? { |x| (40..46).any? { |y| v.pixel_is?(x, y, :white) } }
    assert drew_glyph, "draw_text should render white glyph pixels in buffered mode"
  end

  # The motivating case: a live numeric score renders in buffered mode (draw_number
  # lowers to per-digit draw_text, so this exercises the same RMW path through the
  # DSL). Built through the Builder because draw_number is a DSL verb.
  def test_draw_number_renders_a_score_in_buffered_mode
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      var :score, 42
      clear_screen :blue
      draw_number :score, 40, 40, :white, digits: 2
      wait_vblank
      halt
    end
    b.emit_pending_functions
    prog = b.program

    rom = assemble_rom(prog, name: "SCORE")
    v = assert_gemba_loads_rom(rom, frames: 4)
    drew_digits = (40..60).any? { |x| (40..46).any? { |y| v.pixel_is?(x, y, :white) } }
    assert drew_digits, "a numeric score should render in white in buffered mode"
  end

  # blit still can't draw on the indexed screen (its images are direct-color): a
  # friendly error that names the verbs that do work.
  def test_blit_is_unsupported_in_buffered_mode
    prog = program(
      screen(:bitmap, buffered: true),
      bitmap(:s, width: 2, height: 1, pixels: [Color.resolve(:red), Color.resolve(:blue)].pack("v*")),
      blit(:s, 0, 0),
      halt,
    )
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/blit/, err.message)
    assert_match(/draw_text|pixel|rectangle fills/, err.message) # names what does work
  end

  # --- tear-free fills move two pixels at a time, odd start column included ---

  # A fill moves two side-by-side pixels at once here, so an odd start column is
  # the hard case: the rect's first and last pixel each share a two-pixel unit with
  # a pixel outside the rect, which has to survive. dma_fill_rect(3, ...) must span
  # 3..10 exactly, leaving 2 and 11 as they were.
  def test_a_fill_at_an_odd_start_column_lands_on_that_column
    prog = program(
      screen(:bitmap, buffered: true),
      clear_screen(:blue),
      dma_fill_rect(3, 0, 8, 8, :red),
      wait_vblank, # present the drawn page
      halt,
    )
    rom = assemble_rom(prog, name: "ODDCOL")
    v = assert_gemba_loads_rom(rom, frames: 4)
    assert v.pixel_is?(2, 0, :blue), "the pixel left of the rect keeps its color"
    assert v.pixel_is?(3, 0, :red), "the fill starts on the column it was given"
    assert v.pixel_is?(10, 0, :red), "the 8px fill spans 3..10"
    assert v.pixel_is?(11, 0, :blue), "and stops there — column 11 is untouched background"
  end

  # The narrowest rect at an odd column is all edge and no middle: both its pixels
  # are spliced in one at a time, and there is no block fill between them.
  def test_a_two_pixel_fill_at_an_odd_column_paints_only_its_two_pixels
    prog = program(
      screen(:bitmap, buffered: true),
      clear_screen(:blue),
      dma_fill_rect(5, 0, 2, 4, :red),
      wait_vblank,
      halt,
    )
    rom = assemble_rom(prog, name: "ODD2PX")
    v = assert_gemba_loads_rom(rom, frames: 4)
    assert v.pixel_is?(4, 0, :blue)
    assert v.pixel_is?(5, 0, :red)
    assert v.pixel_is?(6, 0, :red)
    assert v.pixel_is?(7, 0, :blue)
  end

  # --- a full-width band goes in as one unbroken run ---

  # A rect as wide as the screen has no gap between its rows, so it is filled in one
  # transfer rather than one per row. The rows must still land exactly where they were
  # asked for: a band from y=40 to y=79 leaves the row above and the row below alone.
  def test_a_full_width_band_fills_exactly_its_own_rows
    prog = program(
      screen(:bitmap, buffered: true),
      clear_screen(:blue),
      dma_fill_rect(0, 40, 240, 40, :red),
      wait_vblank,
      halt,
    )
    v = assert_gemba_loads_rom(assemble_rom(prog, name: "BAND"), frames: 4)

    assert v.pixel_is?(0, 39, :blue), "the row above the band is untouched"
    assert v.pixel_is?(239, 39, :blue), "...all the way across"
    assert v.pixel_is?(0, 40, :red), "the band starts on the row it was given"
    assert v.pixel_is?(239, 79, :red), "and runs to the far corner of its last row"
    assert v.pixel_is?(0, 80, :blue), "the row below the band is untouched"
  end

  # Two bands that meet must not overlap by so much as a row — the one-transfer path
  # computes its length from w*h, so an off-by-one there would bleed into the next band.
  def test_two_full_width_bands_meet_without_overlapping
    prog = program(
      screen(:bitmap, buffered: true),
      dma_fill_rect(0, 0, 240, 80, :blue),
      dma_fill_rect(0, 80, 240, 80, :red),
      wait_vblank,
      halt,
    )
    v = assert_gemba_loads_rom(assemble_rom(prog, name: "BANDS"), frames: 4)

    assert v.pixel_is?(239, 79, :blue), "the top band owns its last row"
    assert v.pixel_is?(0, 80, :red), "the bottom band starts on the next one"
    assert v.pixel_is?(239, 159, :red), "and reaches the bottom corner of the screen"
  end

  # --- the DSL surface: tear_free: is only for :bitmap ---

  def test_tear_free_is_rejected_for_non_bitmap_modes
    b = RubyGBA::Builder.new
    err = assert_raises(ArgumentError) { b.screen(:tiled, tear_free: true) }
    assert_match(/tear_free/, err.message)
  end
end

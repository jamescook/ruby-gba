# frozen_string_literal: true

require "test_helper"

require_relative "../examples/fonts"

# The fonts example: the same number drawn in :default and :tiny. Asserts both
# render, that the tiny one is genuinely smaller (fewer pixels, shorter box), and
# that the tiny draw emits less code — on the interpreter and gemba.
class TestFontsExample < Minitest::Test
  GREEN = Color.resolve(:green)

  # Count green pixels in a horizontal band [y, y+h).
  def green_in_band(screen, y, h)
    n = 0
    240.times { |x| (y...y + h).each { |yy| n += 1 if screen.pixel(x, yy) == GREEN } }
    n
  end

  def test_both_numbers_render_and_tiny_is_smaller
    screen = Reference.new.run(FontsDemo.program).screen
    default_px = green_in_band(screen, 18, 7) # the default number's 7-tall band
    tiny_px = green_in_band(screen, 54, 5)    # the tiny number's 5-tall band

    assert_operator default_px, :>, 0, "the default-font number should render"
    assert_operator tiny_px, :>, 0, "the tiny-font number should render"
    assert_operator tiny_px, :<, default_px, "the tiny number should plot fewer pixels"
    # the tiny glyphs are only 5 tall — nothing green spills into rows 59..60
    assert_equal 0, green_in_band(screen, 59, 3), "the tiny number should be 5px tall"
  end

  # A smaller glyph is less work, and the honest way to say so is what the build EMITTED for
  # each — a fact, where the old assertion was against an estimate of how long it would take.
  def test_the_tiny_number_emits_less_code
    default = emitted_bytes(build_number(font: :default))
    tiny = emitted_bytes(build_number(font: :tiny))

    assert_operator tiny, :<, default, "the tiny font draws smaller glyphs, so it emits less"
  end

  def emitted_bytes(program)
    RubyGBA::IR::Backends::GBA.new.lower(program).bytesize
  end

  def build_number(font:)
    b = RubyGBA::Builder.new
    b.instance_eval { screen :bitmap; draw_number FontsDemo::SCORE, 8, 8, :green, digits: 5, font: font; halt }
    b.emit_pending_functions
    b.program
  end

  def test_it_renders_on_hardware
    rom = ROM.assemble(GBA.new.lower(FontsDemo.program), title: "FONTS", code: "BFON", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    # green appears in both the default band and the tiny band
    default_green = (8..40).any? { |x| (18..24).any? { |y| v.pixel_is?(x, y, :green) } }
    tiny_green = (8..40).any? { |x| (54..58).any? { |y| v.pixel_is?(x, y, :green) } }
    assert default_green, "default-font number missing on hardware"
    assert tiny_green, "tiny-font number missing on hardware"
  end
end

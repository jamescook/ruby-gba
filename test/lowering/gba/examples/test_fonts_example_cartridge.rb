# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/fonts").to_s

# The fonts example as the Advance's cartridge: what the GBA lowering emits for each font, and
# both numbers drawn in the emulator. What the example draws on every run that plays the
# Advance's games is in test/console/gba/examples/test_fonts_example.rb.
class TestFontsExampleCartridge < Minitest::Test
  # A smaller glyph is less work, and the honest way to say so is what the build EMITTED for
  # each — a fact, where the old assertion was against an estimate of how long it would take.
  def test_the_tiny_number_emits_less_code
    default = emitted_bytes(build_number(font: :default))
    tiny = emitted_bytes(build_number(font: :tiny))

    assert_operator tiny, :<, default, "the tiny font draws smaller glyphs, so it emits less"
  end

  private def emitted_bytes(program)
    VBlank::IR::Backends::GBA.new.lower(program).bytesize
  end

  private def build_number(font:)
    b = VBlank::Builder.new
    b.instance_eval { screen :bitmap; draw_number FontsDemo::SCORE, 8, 8, :green, digits: 5, font: font; halt }
    b.finalize_program
    b.program
  end

  def test_it_renders_on_hardware
    rom = ROM.assemble(GBA.new.lower(FontsDemo.program), title: "FONTS", code: "BFON", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    # green appears in both the default band and the tiny band
    default_green = (8..40).any? { |x| (18..24).any? { |y| v.pixel_is?(x, y, :green) } }
    tiny_green = (8..40).any? { |x| (54..58).any? { |y| v.pixel_is?(x, y, :green) } }
    assert default_green, "default-font number missing on hardware"
    assert tiny_green, "tiny-font number missing on hardware"
  end
end

# frozen_string_literal: true

require "test_helper"
require "all/vblank/graphics/test_image_import"

# The image importer's whole path on the Advance's cartridge: a real image file imported,
# embedded, blitted, and read back in the emulator. The importer itself is tested in
# test/all/vblank/graphics/test_image_import.rb.
class TestImageImportCartridge < Minitest::Test
  include ImageImportGames

  # ---- the whole path: import -> embed -> blit ------------------------------

  def test_imported_image_draws_on_hardware
    rom = VBlank::Cartridge::ROM.assemble(
      VBlank::IR::Backends::GBA.new.lower(photo_program(10, 20)),
      title: "PHOTO", code: "BPHT", maker: "01",
    )
    v = assert_emulator_loads_rom(rom)
    assert v.red?(10, 20),   "top-left red"
    assert v.green?(11, 20), "top-right green"
    assert v.blue?(10, 21),  "bottom-left blue"
    assert v.white?(11, 21), "bottom-right white"
  end

  # ---- the whole path for a CUTOUT: the background shows through -------------

  # The opaque top row draws; the transparent bottom row must let the blue field show
  # through — proving it's a see-through cutout, not a rectangle.
  def test_cutout_shows_background_through_transparent_pixels_on_hardware
    rom = VBlank::Cartridge::ROM.assemble(
      VBlank::IR::Backends::GBA.new.lower(cutout_program(10, 20)),
      title: "CUTOUT", code: "BCUT", maker: "01",
    )
    v = assert_emulator_loads_rom(rom)
    assert v.red?(10, 20),   "opaque top-left"
    assert v.green?(11, 20), "opaque top-right"
    assert v.blue?(10, 21),  "transparent -> field shows"
    assert v.blue?(11, 21),  "transparent -> field shows"
  end
end

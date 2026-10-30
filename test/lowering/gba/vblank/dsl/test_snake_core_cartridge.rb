# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_snake_core"

# The snake's list-driven drawing on the Advance's cartridge, read back in the emulator. What
# every run is held to is in test/all/vblank/dsl/test_snake_core.rb.
class TestSnakeCoreCartridge < Minitest::Test
  include SnakeCoreGames

  # The list-driven draw loop must render on the console as it does headless: the three
  # cells green and the vacated tail cell background.
  def test_the_body_draws_the_same_on_the_console
    rom = VBlank::Cartridge::ROM.assemble(GBA.new.lower(body_drawing_program), title: "SNAKE", code: "BSNK", maker: "01")
    v = assert_emulator_loads_rom(rom)
    BODY_MARKS.each do |x, color|
      assert v.pixel_is?(x, 20, color),
             "console: (#{x}, 20) should be #{color}, got 0x#{format('%04X', v.pixel_gba(x, 20))}"
    end
  end
end

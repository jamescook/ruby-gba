# frozen_string_literal: true

require "test_helper"
require "all/vblank/effects/packs/test_menu"

# `menu` on the Advance's own cartridge: where its console draws the cursor before and after a
# press, read off the screen in the emulator. What a menu does on every run is in
# test/all/vblank/effects/packs/test_menu.rb, which keeps the layout both files use in MenuLayout.
class TestMenuCartridge < Minitest::Test
  include MenuLayout

  # ---- on a tiled screen ----

  def test_a_tiled_menu_moves_on_real_hardware
    require_emulator!
    rom = VBlank.build("TMENU", console: :gba, code: "BTMN", maker: "01", validate: false) do
      screen :tiled
      game_loop do
        menu(:main, at: [X, Y], spacing: SPACING, picked: :white, color: :gray) do |rows|
          ROWS.each_with_index { |label, i| rows.item(label, enabled: i != 1) }
        end
      end
    end

    cursor_pixel = ->(row) { [X - CURSOR_W, Y + (row * SPACING) + 1] }

    still = assert_emulator_loads_rom(rom, frames: 4)

    assert still.white?(*cursor_pixel.call(0)), "the cursor rests beside the first row"

    moved = assert_emulator_loads_rom(rom, frames: 6, keys: VBlank::Console::Hardware::KEY_DOWN)

    assert moved.white?(*cursor_pixel.call(2)),
           "the console composites the cursor onto the row it walked to"
  end

  # ---- on the console ----

  def test_the_cursor_moves_on_real_hardware
    require_emulator!
    rom = VBlank.build("MENU", console: :gba, code: "BMNU", maker: "01", validate: false) do
      screen :bitmap
      game_loop do
        clear_screen :black
        menu(:main, at: [X, Y], spacing: SPACING, picked: :white, color: :gray) do |rows|
          ROWS.each_with_index { |label, i| rows.item(label, enabled: i != 1) }
        end
      end
    end

    # The cursor's ">" is a chevron: its second row is one pixel at the left edge.
    cursor_pixel = ->(row) { [X - CURSOR_W, Y + (row * SPACING) + 1] }

    still = assert_emulator_loads_rom(rom, frames: 4)

    assert still.white?(*cursor_pixel.call(0)), "the cursor rests beside the first row"
    assert still.black?(*cursor_pixel.call(2)), "and nowhere else"

    moved = assert_emulator_loads_rom(rom, frames: 6, keys: VBlank::Console::Hardware::KEY_DOWN)

    assert moved.white?(*cursor_pixel.call(2)),
           "holding down walks past the row that cannot be picked, to row 2"
  end
end

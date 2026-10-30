# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_draw_column_at_on_the_advance"

# The games of test_draw_column_at_on_the_advance.rb on the Advance's cartridge, read back in the
# emulator. What they draw on every Advance run is in
# test/console/gba/vblank/builder/test_draw_column_at_on_the_advance.rb.
class TestDrawColumnAtOnTheAdvanceCartridge < Minitest::Test
  include DrawColumnAtOnTheAdvanceGames

  # A first-person view draws its columns in a LOOP, so this is the case that matters most, and
  # it was broken: a loop keeps its count in the console's registers unless the body needs them,
  # and a stretched column needs them twice over — it works in them, and it calls the divide
  # routine to find its step. Undeclared, the first column drew and the loop then walked off.
  def test_columns_drawn_in_a_loop_all_arrive
    rom = ROM.assemble(GBA.new.lower(columns_in_a_loop), title: "LOOP")
    gba = assert_emulator_loads_rom(rom, frames: 4)
    on_console = (0...8).count { |x| gba.pixel_gba(x, 0) == VBlank::Graphics::Color.resolve(:red) }

    assert_equal 8, on_console, "every column, on the Advance's cartridge"
  end

  # The two backends have to land every pixel in the same place, or the interpreter is no use
  # for debugging a renderer built on this.
  def test_the_console_draws_the_same_pixels_as_the_interpreter
    prog = program do
      tall = var :tall, 0
      game_loop do
        tall.set! 40
        draw_column_at :bars, slice: 0, x: 10, top: 10, height: tall
        draw_column_at :bars, slice: 1, x: 12, top: 10, height: 2
        draw_column_at :bars, slice: 0, x: 14, top: 10, height: 0
        draw_column_at :bars, slice: 0, x: 16, top: -8, height: 24
        draw_column_at :bars, slice: 0, x: 18, top: 150, height: 40
        draw_column_at :bars, slice: 9, x: 20, top: 10, height: 8
      end
    end

    interp = game_player.run(prog, frames: 2)
    rom = ROM.assemble(GBA.new.lower(prog), title: "COLUMN", code: "ACOL", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 4)

    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      interp.screen.pixel(x, y) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end
end

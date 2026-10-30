# frozen_string_literal: true

require "test_helper"

# MANY OF SOMETHING THAT HOLDS A FRACTION, on the Advance's own cartridge: its picture, read in
# the emulator, held to the interpreter's. What a list and a pool field do with a fraction on
# every run is in test/all/vblank/dsl/test_fraction_collections.rb.
class TestFractionCollectionsCartridge < Minitest::Test
  # ON THE CONSOLE TOO. The scale never reaches the IR — it is worked out while building and
  # what comes out is ordinary whole-number arithmetic — so the two backends cannot disagree
  # about it in principle. This is the proof that they do not in practice: a mark whose
  # position on screen is worked out from a list and a pool field that both hold fractions.
  def test_the_console_puts_the_mark_where_the_interpreter_does
    prog = VBlank.game("FRACH", consoles: %i[gba], code: "ZFRH", maker: "01") do
      screen :bitmap
      steps = list :steps, capacity: 4, holds: 0.0
      movers = pool :mover, x: 0.0, capacity: 4
      # Filled once, at the start, so the picture is the same on every frame and the two
      # backends can be held against each other without counting frames.
      steps << 2.5
      movers.spawn(x: 40.0)
      game_loop do
        clear_screen :black
        movers.each { |m| draw_rect_at (m.x + steps[0]).to_i, 40, 4, 4, :green }
      end
    end.program

    interp = game_player.run(prog, frames: 3)
    gba = assert_emulator_loads_rom(assemble_rom(prog, name: "FRACH"), frames: 5)

    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      interp.screen.pixel(x, y) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end
end

# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_fraction_math"

# MULTIPLYING TWO FRACTIONS ON THE ADVANCE'S CARTRIDGE: the marker read off the screen in the
# emulator. The same answer on every run is in test/all/vblank/dsl/test_fraction_math.rb.
class TestFractionMathCartridge < Minitest::Test
  include FractionMathGames

  def test_the_answer_lands_in_the_same_place_on_the_console
    rom = assemble_rom(marker_program, name: "FRACMUL")
    v = assert_emulator_loads_rom(rom, frames: 4)

    assert v.pixel_is?(45, MARKER_Y, :white), "the console must agree with the interpreter"
    assert v.pixel_is?(41, MARKER_Y, :black)
  end
end

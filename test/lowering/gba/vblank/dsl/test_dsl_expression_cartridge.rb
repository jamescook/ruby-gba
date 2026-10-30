# frozen_string_literal: true

require "test_helper"

# A couple of the expression DSL's programs confirmed on the Advance's cartridge, read back in
# the emulator. What the expressions do on every run is in test/all/vblank/dsl/test_dsl_expression.rb.
class TestDSLExpressionCartridge < Minitest::Test
  # Build a real ROM, for the emulator to run.
  private def build(&block)
    VBlank.build("EXPR", console: :gba, validate: false, &block)
  end

  def test_then_gates_a_draw_on_hardware
    rom = build do
      screen :bitmap
      clear_screen :black
      x = var :x, 5
      (x > 3).then { pixel 10, 10, :red }
      (x < 3).then { pixel 20, 20, :blue }
      halt
    end
    v = assert_emulator_loads_rom(rom)
    assert v.red?(10, 10)
    assert v.black?(20, 20)
  end

  def test_and_else_on_hardware
    rom = build do
      screen :bitmap
      clear_screen :black
      x = var :x, 5
      ((x > 1) & (x < 9)).then { pixel 10, 10, :red }.else { pixel 20, 20, :blue }
      halt
    end
    v = assert_emulator_loads_rom(rom)
    assert v.red?(10, 10), "5 is in (1, 9), so the then-branch draws"
    assert v.black?(20, 20)
  end
end

# frozen_string_literal: true

require "test_helper"

# The friendly errors VBlank.build gives for a cartridge's game or maker code it cannot take.
# The cartridge it lays out, byte by byte, is in
# test/lowering/gba/vblank/cartridge/test_rom_builder_cartridge.rb.
class TestRomBuilder < Minitest::Test
  def test_invalid_game_code_raises
    assert_raises(ArgumentError) do
      VBlank.build("TEST", console: :gba, code: "AB", maker: "01") { entry { loop_forever } }
    end
  end

  def test_invalid_maker_code_raises
    assert_raises(ArgumentError) do
      VBlank.build("TEST", console: :gba, code: "ABCD", maker: "X") { entry { loop_forever } }
    end
  end
end

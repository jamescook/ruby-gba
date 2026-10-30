# frozen_string_literal: true

require "test_helper"

# A variant of a console (Console::Variant) is hardware some copies of it have — a Super Nintendo
# cartridge's chip — asked for when a game is built: the console's limits change, and nothing
# else about it does. A console with none, or a name it has no variant by, is refused in plain
# words.
class TestVariant < Minitest::Test
  def test_no_variant_is_the_console_as_it_is
    assert_equal VBlank::Console::SUPER_NINTENDO, VBlank::Console.described(:snes)
    assert_equal VBlank::Console::SUPER_NINTENDO, VBlank::Console.described(:snes, variant: :none)
  end

  def test_a_chip_changes_the_limits_and_nothing_else
    plain = VBlank::Console.described(:snes)
    superfx = VBlank::Console.described(:snes, variant: :superfx)

    assert_operator superfx.roomier_memory_bytes, :>, plain.roomier_memory_bytes
    assert_equal plain.painted_pages, superfx.painted_pages, "a painted screen keeps one page in the chip's RAM too"
    assert_equal plain.screen_size, superfx.screen_size
    assert_equal plain.buttons, superfx.buttons
    assert_includes superfx.title, "Super FX"
  end

  def test_a_variant_the_console_has_not_is_refused_naming_the_ones_it_has
    error = assert_raises(ArgumentError) { VBlank::Console.described(:snes, variant: :cx4) }
    assert_includes error.message, ":superfx"

    error = assert_raises(ArgumentError) { VBlank::Console.described(:gba, variant: :superfx) }
    assert_includes error.message, "no variants"
  end
end

# frozen_string_literal: true

require "test_helper"

# A SETTING THAT CANNOT BE RIGHT STOPS THE GAME AT THE LINE THAT SAID IT, before anything is read
# or built.
class TestOptions < Minitest::Test
  # Every build names the console its cartridge is for; nothing is taken to be for the Advance.
  def test_a_build_that_names_no_console_is_refused
    error = assert_raises(ArgumentError) { VBlank.build("NOCONSOLE", out: nil, err: nil) { halt } }

    assert_match(/NOCONSOLE names no console/, error.message)
    assert_match(/console: :gba/, error.message)
  end

  # A console named in a String is the console of that name, and the cartridge is that console's.
  def test_a_console_named_in_a_string_builds_that_consoles_cartridge
    { "gba" => VBlank::Cartridge::ROM, "gbc" => VBlank::Cartridge::GBCROM }.each do |name, kind|
      rom = VBlank.build("STRINGED", console: name, out: nil, err: nil) do
        screen :bitmap
        game_loop { pixel 1, 1, :white }
      end

      assert_instance_of kind, rom, name
    end
  end

  def test_a_variant_without_a_console_is_refused
    error = assert_raises(ArgumentError) { VBlank::Cartridge::Options.new(variant: :superfx) }

    assert_match(/A variant needs a console/, error.message)
  end

  # "none" is the console as it is, so the variant is nil.
  def test_a_variant_named_none_is_the_plain_console
    assert_nil VBlank::Cartridge::Options.new(console: :snes, variant: "none").variant
    assert_equal :superfx, VBlank::Cartridge::Options.new(console: :snes, variant: "superfx").variant
  end
end

# frozen_string_literal: true

require "test_helper"

# A SETTING THAT CANNOT BE RIGHT STOPS THE GAME AT THE LINE THAT SAID IT, before anything is read
# or built.
class TestOptions < Minitest::Test
  # How much of the quick memory the game's stack is given: a number of bytes the stack can hold
  # whole numbers in, from the least the console's own routines need to half the quick memory.
  def test_stack_room_the_stack_cannot_have_is_refused
    [1001, 32, 32_768, "lots", 1024.0].each do |wrong|
      error = assert_raises(ArgumentError) { RubyGBA.game("BADSTACK", consoles: %i[gba], stack_room: wrong) { halt } }

      assert_match(/stack_room: #{Regexp.escape(wrong.inspect)}/, error.message)
      assert_match(/multiple of 4/, error.message)
    end
  end

  def test_stack_room_a_stack_can_have_is_taken
    [64, 512, 16_384].each do |room|
      assert_equal room, RubyGBA.game("GOODSTACK", consoles: %i[gba], stack_room: room) { halt }.options.stack_room
    end
  end

  # Every build names the console its cartridge is for; nothing is taken to be for the Advance.
  def test_a_build_that_names_no_console_is_refused
    error = assert_raises(ArgumentError) { RubyGBA.build("NOCONSOLE", out: nil, err: nil) { halt } }

    assert_match(/NOCONSOLE names no console/, error.message)
    assert_match(/console: :gba/, error.message)
  end

  # A console named in a String is the console of that name, and the cartridge is that console's.
  def test_a_console_named_in_a_string_builds_that_consoles_cartridge
    { "gba" => RubyGBA::Cartridge::ROM, "gbc" => RubyGBA::Cartridge::GBCROM }.each do |name, kind|
      rom = RubyGBA.build("STRINGED", console: name, out: nil, err: nil) do
        screen :bitmap
        game_loop { pixel 1, 1, :white }
      end

      assert_instance_of kind, rom, name
    end
  end
end

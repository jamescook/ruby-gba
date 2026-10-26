# frozen_string_literal: true

require "test_helper"

require "stringio"

# A CARTRIDGE IS READ BACK BY THE READER ITS CONSOLE'S KIT NAMES (Verifier.for, Console::Kit#reader):
# an Advance cartridge by a Verifier, a Game Boy Color one by a GBCVerifier.
class TestVerifierFor < Minitest::Test
  def setup
    require_emulator!
  end

  def test_each_cartridge_is_read_back_by_its_kits_reader
    RubyGBA::Console.kits.each do |kit|
      rom = RubyGBA.build("READER", console: kit.name, out: StringIO.new, err: StringIO.new) do
        screen :tiled
        image(:dot, "#" => :white) { "########\n" * 8 }
        sprite :dot, at: [8, 8]
        game_loop {}
      end
      reader = RubyGBA::Diagnostics::Verifier.for(rom, frames: 2)

      assert_instance_of kit.reader, reader
      assert_equal kit.description.screen_size, [reader.screen_width, reader.screen_height],
                   "the #{kit.title} cartridge is read back at its own screen's size"
    end
  end
end

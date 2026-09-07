# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/wolf3d"

# Run from this directory: cd games/wolf3d && rake test:parallel
module Wolf3DTest
  Reference = RubyGBA::IR::Backends::Reference # the oracle: runs a program in-process
  GBA = RubyGBA::IR::Backends::GBA
  Builder = RubyGBA::Builder
  ROM = RubyGBA::ROM

  # A real copy of the game, for the few tests that check us against the world rather than
  # against ourselves. The suite never depends on one being here.
  def game_data_or_skip
    Wolf3D::GameData.find ||
      skip("no copy of Wolfenstein 3D found — set #{Wolf3D::GameData::ENV_VAR} to check against one")
  end

  # THE SMALLEST CARTRIDGE THAT IS STILL THIS GAME, for the two tests that build the whole
  # thing rather than a floor of their own.
  #
  # The build ships every episode your copy holds, which is right for playing and wrong here:
  # on the registered release that is sixty floors, an 8MB cartridge and about a minute, and
  # what these tests want to know is only that the wiring works. One floor is a few seconds and
  # proves the same thing. Each test process has its own environment, so this cannot leak into
  # another one.
  def a_small_cartridge
    was = ENV.fetch("WOLF3D_FLOORS", nil)
    ENV["WOLF3D_FLOORS"] = "1"
    yield
  ensure
    was ? ENV["WOLF3D_FLOORS"] = was : ENV.delete("WOLF3D_FLOORS")
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/wolf3d"

# Run from this directory: cd games/wolf3d && rake test
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
end

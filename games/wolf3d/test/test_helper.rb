# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/wolf3d"

# Run from this directory: cd games/wolf3d && rake test
module Wolf3DTest
  Reference = RubyGBA::IR::Backends::Reference # the oracle: runs a program in-process
  GBA = RubyGBA::IR::Backends::GBA
  Builder = RubyGBA::Builder
  ROM = RubyGBA::ROM
end

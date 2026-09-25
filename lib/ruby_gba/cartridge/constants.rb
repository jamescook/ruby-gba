# frozen_string_literal: true

module RubyGBA
  module Cartridge
    # THE OLD NAME, kept for games written against it. The console's addresses and flags are
    # Console::Hardware, and the header layout is Cartridge::Header; this reaches both, so
    # `include RubyGBA::Cartridge::Constants` and `RubyGBA::Cartridge::Constants::KEY_DOWN` go
    # on working. Nothing in this library uses it. It goes once the games that name it have
    # moved to the new names.
    module Constants
      include Console::Hardware
      include Header
    end
  end
end

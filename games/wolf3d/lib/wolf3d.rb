# frozen_string_literal: true

# Wolfenstein 3D, built with ruby-gba. Needs a copy of the game you own — see README.md.

begin
  require "ruby_gba"
rescue LoadError
  # Not installed as a gem. This game sits inside the ruby-gba tree, so fall back to the copy
  # beside it — the public entry point only, never the internals.
  $LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
  require "ruby_gba"
end

require_relative "wolf3d/title"

module Wolf3D
  TITLE = "WOLF3D"
  # A made-up game code. The real one belongs to the 2002 release, and using it would make
  # emulators and flashcarts treat this cartridge as that one.
  CODE = "AWLF"
  MAKER = "01"

  GAME = RubyGBA.game(TITLE, code: CODE, maker: MAKER) do
    screen :bitmap, tear_free: true

    title = Title.new(self)
    game_loop { title.update }
  end

  def self.program = GAME.program
  def self.build_rom(**) = GAME.build_rom(**)
end

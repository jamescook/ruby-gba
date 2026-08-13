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

require_relative "wolf3d/codec/rlew"
require_relative "wolf3d/codec/carmack"
require_relative "wolf3d/codec/huffman"
require_relative "wolf3d/game_data"
require_relative "wolf3d/palette"
require_relative "wolf3d/level"
require_relative "wolf3d/maps"
require_relative "wolf3d/vswap"
require_relative "wolf3d/fixture/release"
require_relative "wolf3d/map_view"
require_relative "wolf3d/palette_view"
require_relative "wolf3d/art_view"
require_relative "wolf3d/title"

module Wolf3D
  TITLE = "WOLF3D"
  # A made-up game code. The real one belongs to the 2002 release, and using it would make
  # emulators and flashcarts treat this cartridge as that one.
  CODE = "AWLF"
  MAKER = "01"

  # This game's own directory, which is where wolf3d.yml is looked for.
  def self.home = File.expand_path("..", __dir__)

  # Nil until someone points the build at their copy. The game still builds without it, so the
  # cartridge can say what is missing instead of the build dying.
  def self.data = @data ||= GameData.find

  def self.maps = @maps ||= data && Maps.from(data)
  def self.vswap = @vswap ||= data && Vswap.from(data)

  def self.palette = Palette.game

  # Say what the cartridge was built from, or how to fix it not knowing.
  def self.report(err = $stderr)
    data ? err.puts(data.describe) : err.puts(GameData.unset_message(home))
    data
  end

  GAME = RubyGBA.game(TITLE, code: CODE, maker: MAKER) do
    screen :bitmap

    level = Wolf3D.maps&.[](0)
    if level
      map = Wolf3D::MapView.new(self, level).declare
      art = Wolf3D::ArtView.new(self, Wolf3D.palette)
             .add(:wall, Wolf3D.vswap.wall(0), at: [8, 6])
             .add(:thing, Wolf3D.vswap.sprite(50), at: [8, 44])
      colours = Wolf3D::PaletteView.new(self, Wolf3D.palette).declare

      # None of this moves, so it is drawn once rather than every frame. The framework says so
      # if you get it wrong: a full repaint of a screen this busy does not fit the moment a
      # frame has to change the picture.
      draw_text level.name.upcase, 60, 2, :white
      map.draw
      art.draw
      colours.draw
      game_loop { halt }
    else
      title = Title.new(self)
      game_loop { title.update }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**) = GAME.build_rom(**)
end

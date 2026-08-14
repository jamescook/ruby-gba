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
require_relative "wolf3d/doors"
require_relative "wolf3d/pushwalls"
require_relative "wolf3d/guards"
require_relative "wolf3d/scenery"
require_relative "wolf3d/fixture/release"
require_relative "wolf3d/wall_atlas"
require_relative "wolf3d/thing_atlas"
require_relative "wolf3d/status_bar"
require_relative "wolf3d/first_person"
# ...after the view, whose constants they share: the three agree about how wide the lens is, and
# where the middle of the screen falls is what a shot is aimed by.
require_relative "wolf3d/billboards"
require_relative "wolf3d/guard_mind"
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
    # Drawn on the tear-free screen, and it has to be. A first-person view repaints every
    # pixel every frame, and this one costs more than a frame holds — so on a screen the
    # display reads while the game is still drawing it, the player watches the picture
    # arrive, half a corridor at a time. Here the frame is drawn out of sight and shown
    # whole, so a frame that takes too long shows the previous one again rather than a
    # torn one.
    screen :bitmap, tear_free: true

    level = Wolf3D.maps&.[](0)
    if level
      doors = Wolf3D::Doors.new(level, Wolf3D.vswap)
      pushwalls = Wolf3D::Pushwalls.new(level)
      guards = Wolf3D::Guards.new(level)
      scenery = Wolf3D::Scenery.new(level)
      atlas = Wolf3D::WallAtlas.new(Wolf3D.vswap, Wolf3D.palette, level, doors: doors)
      things = Wolf3D::ThingAtlas.new(Wolf3D.vswap, Wolf3D.palette,
                                      (guards.pictures + scenery.pictures).uniq.sort)
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, guards: guards, things: things,
                                     scenery: scenery)
      game_loop { view.update }
    else
      title = Title.new(self)
      game_loop { title.update }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**) = GAME.build_rom(**)
end

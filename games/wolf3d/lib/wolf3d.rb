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
require_relative "wolf3d/vgagraph"
require_relative "wolf3d/doors"
require_relative "wolf3d/pushwalls"
require_relative "wolf3d/elevator"
# ...after the doors, whose panels are the only thing that joins one room to the next.
require_relative "wolf3d/rooms"
require_relative "wolf3d/guards"
require_relative "wolf3d/scenery"
# ...after all of them, because a floor is made of every one.
require_relative "wolf3d/floors"
require_relative "wolf3d/fixture/release"
require_relative "wolf3d/wall_atlas"
require_relative "wolf3d/thing_atlas"
require_relative "wolf3d/bar_art"
require_relative "wolf3d/status_bar"
require_relative "wolf3d/first_person"
# ...after the view, whose constants say how big the part of the screen that goes red is.
require_relative "wolf3d/dying"
# ...and after dying, which is the only thing that ever spends one.
require_relative "wolf3d/lives"
# ...and after the view, whose START_HEALTH and KEY_BITS say what a full player is and what a key
# is worth, and after lives, which a one-up on the floor hands another of.
require_relative "wolf3d/pickups"
require_relative "wolf3d/sounds"
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

  # WHICH FLOORS THE CARTRIDGE HOLDS, and how many is a build-time choice rather than a fixed
  # number, because it is the one dial with a real trade on either end. Each floor adds its map,
  # its blocking, its doors, its walls that move, its guards and everything lying on it — nothing
  # to the frame, all of it to the ROM and to the time the build takes. A test wants one; a game
  # wants an episode.
  #
  #   WOLF3D_FLOORS=3 ruby wolf3d.rb
  #
  # An episode is ten: eight ordinary floors, the boss, and the secret one kept aside.
  EPISODE = 10

  # ...AND WHICH ONE IT STARTS AT, which is a measuring tool rather than a way to play. A
  # cartridge boots on the first floor it holds, so the only way to read what a LATER floor costs
  # is to build one that begins there:
  #
  #   WOLF3D_FROM=1 WOLF3D_FLOORS=1 ruby ../../bin/ruby-gba explain wolf3d.rb
  #
  # Floors differ enormously in what stands on them — the second floor of the first episode
  # carries three times the guards and three times the scenery of the first — so "what does a
  # frame cost" has no single answer for a game, only one per floor.
  def self.which_floors
    from = Integer(ENV.fetch("WOLF3D_FROM", 0))
    asked = Integer(ENV.fetch("WOLF3D_FLOORS", EPISODE))
    (from...[from + asked, maps.count].min).to_a
  end
  def self.vswap = @vswap ||= data && Vswap.from(data)

  def self.vgagraph = @vgagraph ||= data && Vgagraph.from(data)

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

    if Wolf3D.maps
      floors = Wolf3D::Floors.from(Wolf3D.maps, Wolf3D.vswap, Wolf3D.which_floors)
      atlas = Wolf3D::WallAtlas.new(Wolf3D.vswap, Wolf3D.palette, floors.map(&:level),
                                    doors: floors.map(&:doors), lifts: floors.map(&:lifts))
      things = Wolf3D::ThingAtlas.new(Wolf3D.vswap, Wolf3D.palette,
                                      floors.flat_map { |f|
                                        f.guards.pictures + f.scenery.pictures +
                                          Wolf3D::Pickups.pictures(f.guards)
                                      }.uniq.sort)
      view = Wolf3D::FirstPerson.new(build: self, floors: floors, atlas: atlas, things: things,
                                     vswap: Wolf3D.vswap,
                                     bar_art: Wolf3D::BarArt.of(Wolf3D.vgagraph))
      game_loop { view.update }
    else
      title = Title.new(self)
      game_loop { title.update }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**) = GAME.build_rom(**)
end

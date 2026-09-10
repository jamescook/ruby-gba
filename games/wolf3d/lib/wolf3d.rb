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
# ...and the pictures of the gun in your hands, which are the last twenty sprites of it. Up
# here with the reader rather than beside the other two atlases, because a release written for
# the tests has to know how many sprites it must hold to have them.
require_relative "wolf3d/weapon_atlas"
require_relative "wolf3d/vgagraph"
require_relative "wolf3d/doors"
require_relative "wolf3d/pushwalls"
require_relative "wolf3d/elevator"
# ...after the doors, whose panels are the only thing that joins one room to the next.
require_relative "wolf3d/rooms"
# WHAT THE FIVE KINDS OF ENEMY ARE, then how a cartridge lays their states out, then how a floor
# is read for them. Each needs the one before it.
require_relative "wolf3d/enemy"
require_relative "wolf3d/behaviour"
require_relative "wolf3d/guards"
require_relative "wolf3d/scenery"
# ...after all of them, because a floor is made of every one.
require_relative "wolf3d/floors"
require_relative "wolf3d/fixture/release"
require_relative "wolf3d/wall_atlas"
require_relative "wolf3d/thing_atlas"
require_relative "wolf3d/bar_art"
require_relative "wolf3d/menu_art"
require_relative "wolf3d/status_bar"
require_relative "wolf3d/first_person"
# ...after the view, whose height is what the gun's square is scaled to.
require_relative "wolf3d/weapons"
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
# ...after the view, which the menus put themselves in front of and hand a game back to.
require_relative "wolf3d/menus"
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

  # WHICH EPISODES THE CARTRIDGE HOLDS. Every one your copy has, unless you say otherwise —
  # and it is said in EPISODES because that is how the game is divided, how its own menu asks
  # you to choose, and the only unit anybody playing it thinks in.
  #
  #   WOLF3D_EPISODES=1      just the first
  #   WOLF3D_EPISODES=1,3    the first and the third
  #   WOLF3D_EPISODES=2-4    the second to the fourth
  #
  # WHAT IT COSTS IS ROM AND BUILD TIME AND NOTHING IN THE FRAME. Each floor adds its map, its
  # blocking, its doors, its walls that move, its guards and everything lying on it, and none
  # of that is work the game does while somebody is playing. Measured on the registered
  # release: all six episodes is an 8MB cartridge and about a minute to build, against 4MB and
  # eight seconds for one. So the whole game is the default and trimming it is for when you are
  # building over and over.
  def self.which_episodes
    asked = ENV.fetch("WOLF3D_EPISODES", nil).to_s.strip
    return (1..maps.episodes).to_a if asked.empty?

    episodes_named(asked)
  end

  # A number, a list of them, or a range — "1", "1,3", "2-4", or any of those joined by commas.
  def self.episodes_named(asked)
    wanted = asked.split(",").flat_map { |part| an_episode_range(part) }.uniq.sort
    outside = wanted.reject { |n| (1..maps.episodes).cover?(n) }
    return wanted if outside.empty?

    raise ArgumentError,
          "WOLF3D_EPISODES asks for episode #{outside.join(' and ')}. This copy of the game " \
          "holds #{maps.episodes}. Give a number from 1 to #{maps.episodes}, a list like 1,3, " \
          "or a range like 2-4."
  end

  def self.an_episode_range(part)
    first, last = part.split("-", 2).map { |n| Integer(n.strip) }
    (first..(last || first)).to_a
  rescue ArgumentError
    raise ArgumentError,
          "WOLF3D_EPISODES cannot read #{part.strip.inspect}. Give a number like 1, a list " \
          "like 1,3, or a range like 2-4."
  end

  # ...AND WHICH FLOORS OF THOSE, which is a measuring tool rather than a way to play. A
  # cartridge boots on the first floor it holds, so the only way to read what a LATER floor
  # costs is to build one that begins there:
  #
  #   WOLF3D_FROM=1 WOLF3D_FLOORS=1 ruby ../../bin/ruby-gba profile wolf3d.rb
  #
  # Floors differ enormously in what stands on them — the second floor of the first episode
  # carries three times the guards and three times the scenery of the first — so "what does a
  # frame cost" has no single answer for a game, only one per floor. WOLF3D_FLOORS on its own
  # is also the fastest build there is, which is what you want while changing something else.
  def self.which_floors
    floors = which_episodes.flat_map { |episode| maps.floors_of(episode) }
    floors = floors.drop(Integer(ENV.fetch("WOLF3D_FROM", 0)))
    asked = ENV.fetch("WOLF3D_FLOORS", nil)
    asked ? floors.first(Integer(asked)) : floors
  end
  # WHICH SCREEN THE CARTRIDGE BOOTS ON, which is a measuring tool rather than a way to play —
  # the same kind of dial as WOLF3D_FROM above. The attract loop takes a quarter of a minute to
  # come round, and the episode list only exists on a cartridge carrying more than one episode,
  # so a cartridge that boots straight to the screen you want to look at saves a lot of waiting:
  #
  #   WOLF3D_SCREEN=credits ruby wolf3d.rb
  #
  # The screens are: notice, title, credits, menu, episodes, difficulty, playing.
  def self.which_screen = Menus.screen_named(ENV.fetch("WOLF3D_SCREEN", nil))

  def self.vswap = @vswap ||= data && Vswap.from(data)

  def self.vgagraph = @vgagraph ||= data && Vgagraph.from(data)

  # The pictures of the gun in your hands, or nil for a copy of the game that does not hold
  # them — in which case the four weapons still work and you simply cannot see the one you have.
  def self.gun_art
    @gun_art ||= WeaponAtlas.in?(vswap) ? WeaponAtlas.new(vswap, palette) : nil
  end

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
      # WOLFENSTEIN'S OWN MENU ART, or nil for a release whose pictures we cannot name — and
      # then the cartridge boots straight into the game, because there is nothing to write a
      # menu with.
      menu_art = Wolf3D::MenuArt.of(Wolf3D.vgagraph)
      # WHETHER SOUND IS ON, which the menu's own row moves and every one of the game's sounds
      # is played under. Declared here rather than inside either of them because both need it
      # and neither owns it.
      sound_on = menu_art && var(:sound_on, 1)
      # `gun_art` is the pictures of the gun in your hands, and it is asked of the CARTRIDGE
      # rather than of the level: every floor is played holding the same four weapons, where the
      # walls and the things standing in the rooms differ from one floor to the next.
      view = Wolf3D::FirstPerson.new(build: self, floors: floors, atlas: atlas, things: things,
                                     vswap: Wolf3D.vswap,
                                     bar_art: Wolf3D::BarArt.of(Wolf3D.vgagraph),
                                     gun_art: Wolf3D.gun_art,
                                     startable: !menu_art.nil?, sound_on: sound_on)
      if menu_art
        menus = Wolf3D::Menus.new(build: self, view: view, art: menu_art,
                                  palette: Wolf3D.palette, sound_on: sound_on,
                                  starting_on: Wolf3D.which_screen)
        game_loop { menus.update }
      else
        game_loop { view.update }
      end
    else
      title = Title.new(self)
      game_loop { title.update }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**) = GAME.build_rom(**)
end

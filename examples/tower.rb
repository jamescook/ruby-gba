#!/usr/bin/env ruby
# frozen_string_literal: true

# A tower of three floors, climbed by its stairs — on the Game Boy Advance and the Game Boy Color
# alike.
#
# Walk with the arrows. Each floor has a staircase somewhere; stand on it and you are on the floor
# above, back at the door. The roof has a gate in its wall, and A opens it.
#
# Every floor is a scene, and every scene declares a background by the same name, :floor — the
# way a game writes its levels. Each one has a map of its own, tiles of its own (stone, then
# wood, then the roof's tiles with the gate among them) and walls of its own, and the hero is
# stopped by the walls of the floor it is on. A line that names :floor, like the roof showing its
# map with the gate open, changes the floor that is up. Nothing below says where any of it goes
# in the console.

require_relative "../lib/vblank"

module Tower
  SOLID = (["########"] * 8).join("\n").freeze
  HERO = <<~ART
    ..####..
    ..####..
    ...##...
    .######.
    #.####.#
    ..####..
    ..#..#..
    .##..##.
  ART
  STEPS = <<~ART
    ########
    ........
    ########
    ........
    ########
    ........
    ########
    ........
  ART

  # 20 cells across and 18 down, which both consoles show whole. "#" is wall, "." floor, "^" the
  # stairs up, and on the roof "=" the gate. Every way through a wall is two cells wide.
  GROUND = Ractor.make_shareable(<<~MAP.lines.map(&:chomp))
    ####################
    #.................^#
    #..................#
    #...######.........#
    #...#....#.........#
    #...#....#.........#
    #...#....#.........#
    #...##..##.........#
    #..................#
    #..................#
    #..........#####...#
    #..................#
    #..................#
    #..................#
    #..................#
    #..................#
    #..................#
    ####################
  MAP
  UPSTAIRS = Ractor.make_shareable(<<~MAP.lines.map(&:chomp))
    ####################
    #................^.#
    #..................#
    #..................#
    #..................#
    ################..##
    #.................##
    #.................##
    #.....#####.......##
    #.................##
    #.................##
    ##..################
    #..................#
    #..................#
    #..................#
    #..................#
    #..................#
    ####################
  MAP
  ROOF = Ractor.make_shareable(<<~MAP.lines.map(&:chomp))
    ####################
    #..................#
    #..................#
    #..................#
    #..................#
    #..................#
    #..................#
    #..................#
    #########==#########
    #..........#.......#
    #..........#.......#
    #..........#.......#
    #..........#.......#
    #..........#.......#
    #..........#.......#
    #..........#.......#
    #..........#.......#
    ####################
  MAP

  # ...and the roof with its gate open, a map of its own: what a wall is follows the map showing.
  ROOF_OPEN = Ractor.make_shareable(ROOF.map { |row| row.tr("=", ".") })

  # Where the hero starts on every floor: just inside, at the bottom left.
  START = Ractor.make_shareable([16, 120])

  # The stairs of each floor, as a cell.
  STAIRS = Ractor.make_shareable({ ground: [18, 1], upstairs: [17, 1] })

  # One of the two cells of the gate on the roof.
  GATE = Ractor.make_shareable([9, 8])

  GAME = VBlank.game("TOWER", consoles: %i[gba gbc]) do
    screen :tiled
    image(:hero, "#" => :white, "." => :transparent) { HERO }
    image(:stone_wall, "#" => :gray) { SOLID }
    image(:stone, "#" => :black) { SOLID }
    image(:wood_wall, "#" => :red) { SOLID }
    image(:wood, "#" => :orange) { SOLID }
    image(:parapet, "#" => :cyan) { SOLID }
    image(:roof, "#" => :blue) { SOLID }
    image(:gate, "#" => :yellow) { SOLID }
    image(:steps, "#" => :white, "." => :gray) { STEPS }
    tiles :stone_tiles, "#" => :stone_wall, "." => :stone, "^" => :steps, solid: ["#"]
    tiles :wood_tiles, "#" => :wood_wall, "." => :wood, "^" => :steps, solid: ["#"]
    tiles :roof_tiles, "#" => :parapet, "." => :roof, "=" => :gate, solid: ["#", "="]

    hero = sprite :hero, at: START
    level = var :level, 0

    # One floor: its own :floor, the hero walking it and stopped by its walls, and the stairs
    # up, where it has any.
    climb = lambda do |floor, stairs|
      hero.blocked_by floor
      held(:left).then { hero.move :left, by: 2 }
      held(:right).then { hero.move :right, by: 2 }
      held(:up).then { hero.move :up, by: 2 }
      held(:down).then { hero.move :down, by: 2 }
      next unless stairs

      col, row = stairs
      on_stairs = ((hero.x + 4) / 8 == col) & ((hero.y + 4) / 8 == row)
      on_stairs.then do
        level.add! 1
        hero.move_to(*START)
      end
    end

    scene(:ground) { climb.call(background(:floor, tiles: :stone_tiles, map: GROUND), STAIRS[:ground]) }
    scene(:upstairs) { climb.call(background(:floor, tiles: :wood_tiles, map: UPSTAIRS), STAIRS[:upstairs]) }
    # The roof has two maps, the gate shut and the gate open, and A shows the second: the
    # picture and the walls change together, so the hero can walk through.
    gate = var :gate, 0
    scene(:roof) do
      floor = background :floor, tiles: :roof_tiles, map: { shut: ROOF, open: ROOF_OPEN }
      climb.call(floor, nil)
      pressed(:a).then { gate.set! 1 }
      floor.show_map gate
    end

    game_loop do
      case_var(:level) do
        when_val 0, :ground
        when_val 1, :upstairs
        when_val 2, :roof
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Tower::GAME.write_if_main

#!/usr/bin/env ruby
# frozen_string_literal: true

# Meadow — walk out of a cabin into a room far bigger than the screen.
#
# A room in a real game is often many screens across: an overworld field, a town, a
# forest. The console holds a background grid of at most 64x64 cells, which is four
# screens, and the meadow here is 120x100 cells — 960x800 pixels, four screens across and
# five down. You write it at that size and scroll over it like any other background.
#
# What the framework does underneath is what retail games do for their big rooms: it
# keeps the whole meadow in the cartridge and, in the gap before each frame, copies the
# column or row of cells that is coming into view. Nothing in this file says so.
#
# The cabin and the meadow are TWO ROOMS OF DIFFERENT SIZES on one background. The cabin
# is one screen; the meadow is twenty. Each is kept at its own size, so the cabin does
# not cost the meadow's room. Walk down through the cabin door and `show_map` hands the
# background the meadow, filled around wherever the view lands on that same frame; walk
# up into the cabin's door in the meadow to go back in.
#
# One thing changes at the edge of a room this big: past it there is nothing, so the
# view would show the backdrop rather than the meadow coming round again. The view here
# stops at the edges, which is what a room wants anyway.
#
# The hero walks over everything; walls are left out to keep this short (see
# examples/hero.rb for a hero that trees stop).
#
# Run it to build examples/meadow.gba:
#   ruby examples/meadow.rb

require_relative "../lib/ruby_gba"

module Meadow
  SPEED = 2
  HERO = 16 # the hero is 16 pixels each way

  # THE CABIN: one screen, 30x20 cells. Walls round the edge, a rug in the middle, and the
  # door in the bottom wall at columns 14 and 15.
  CABIN = Ractor.make_shareable((0...20).map do |r|
    (0...30).map do |c|
      if r == 19 && [14, 15].include?(c) then "D"
      elsif r.zero? || r == 19 || c.zero? || c == 29 then "#"
      elsif (8..11).cover?(r) && (11..18).cover?(c) then "r"
      else "."
      end
    end.join
  end)

  # THE MEADOW: 120x100 cells. A ring of trees round the edge, trees and flowers scattered
  # through the grass, a pond in the north-east, a path crossing it, and the cabin seen
  # from outside — a roof, a front wall and its door at columns 53 and 54 of row 45.
  COLS = 120
  ROWS = 100
  CABIN_COLS = (50..57)
  CABIN_ROWS = (40..45)
  DOOR_COLS = [53, 54].freeze

  def self.meadow_cell(r, c)
    if CABIN_ROWS.cover?(r) && CABIN_COLS.cover?(c)
      if r < 45 then "^"
      elsif DOOR_COLS.include?(c) then "D"
      else "#"
      end
    elsif r < 2 || r >= ROWS - 2 || c < 2 || c >= COLS - 2 then "T"
    elsif (((c - 92)**2) * 36) + (((r - 22)**2) * 100) <= 3600 then "~" # an oval pond
    elsif (r > 45 && DOOR_COLS.include?(c)) || r == 70 then "=" # the path
    elsif ((r * 7) + (c * 13)) % 23 == 0 then "T"
    elsif ((r * 5) + (c * 3)) % 17 == 0 then "*"
    else "."
    end
  end

  MEADOW = Ractor.make_shareable((0...ROWS).map { |r| (0...COLS).map { |c| meadow_cell(r, c) }.join })

  # Where the hero stands on walking through each door, in the room's own pixels.
  INSIDE_DOOR = [(14 * 8), (19 * 8) - HERO - 12].freeze
  OUTSIDE_DOOR = [(53 * 8), (46 * 8) + 4].freeze

  GAME = RubyGBA.game("MEADOW") do
    screen :tiled

    image :grass, "." => rgb(3, 18, 5), "'" => rgb(5, 24, 7) do
      <<~ART
        ........
        ..'.....
        ........
        .....'..
        ........
        ...'....
        ........
        ......'.
      ART
    end
    image :flower, "." => rgb(3, 18, 5), "o" => :yellow, "x" => :red do
      <<~ART
        ........
        ..o.....
        .oxo....
        ..o.....
        .....o..
        ....oxo.
        .....o..
        ........
      ART
    end
    image :tree, "^" => rgb(0, 22, 0), "|" => rgb(12, 7, 2), "." => rgb(3, 18, 5) do
      <<~ART
        ...^^...
        ..^^^^..
        .^^^^^^.
        ^^^^^^^^
        ..^^^^..
        ...||...
        ...||...
        ..|||...
      ART
    end
    image :water, "~" => :blue, "=" => rgb(12, 12, 31) do
      <<~ART
        ~~~~~~~~
        ~~==~~~~
        ~~~~~~~~
        ~~~~~~==
        ==~~~~~~
        ~~~~~~~~
        ~~~==~~~
        ~~~~~~~~
      ART
    end
    image :path, "." => rgb(20, 15, 8), "o" => rgb(16, 11, 5) do
      <<~ART
        ........
        ...o....
        ........
        ......o.
        .o......
        ........
        ....o...
        ........
      ART
    end
    image :wall, "#" => rgb(16, 9, 4), "." => rgb(10, 5, 2) do
      <<~ART
        ########
        ########
        ........
        ########
        ########
        ........
        ########
        ########
      ART
    end
    image :roof, "#" => rgb(20, 4, 4), "." => rgb(14, 2, 2) do
      <<~ART
        ########
        .#######
        ########
        ###.####
        ########
        #######.
        ########
        ####.###
      ART
    end
    image :door, "#" => rgb(8, 4, 1), "o" => :yellow do
      <<~ART
        ########
        ########
        ########
        ######o#
        ########
        ########
        ########
        ########
      ART
    end
    image :boards, "." => rgb(18, 12, 6), "|" => rgb(13, 8, 3) do
      <<~ART
        ...|....
        ...|....
        ...|....
        ||||||||
        .......|
        .......|
        .......|
        ||||||||
      ART
    end
    image :rug, "." => rgb(6, 6, 20), "o" => rgb(20, 20, 4) do
      <<~ART
        ........
        .o....o.
        ........
        ...oo...
        ...oo...
        ........
        .o....o.
        ........
      ART
    end

    tiles :land, "." => :grass, "*" => :flower, "T" => :tree, "~" => :water, "=" => :path,
                 "#" => :wall, "^" => :roof, "D" => :door, "r" => :rug, "b" => :boards
    # The cabin's floor is boards rather than grass: the same tileset, another key.
    cabin = CABIN.map { |row| row.tr(".", "b") }
    world = background :world, tiles: :land, map: { cabin: cabin, meadow: MEADOW }

    image :hero_art, "." => :transparent, "o" => rgb(31, 24, 18), "#" => :blue, "h" => rgb(12, 6, 2) do
      <<~ART
        ......hhhh......
        .....hhhhhh.....
        .....oooooo.....
        .....o.oo.o.....
        .....oooooo.....
        ......oooo......
        ....########....
        ...##########...
        ...o########o...
        ...o########o...
        ....########....
        ....###..###....
        ....###..###....
        ....hhh..hhh....
        ...hhhh..hhhh...
        ................
      ART
    end
    hero = sprite :hero_art, at: [112, 72]

    room = var :room, 0 # 0 is the cabin, 1 the meadow — the map number show_map takes
    x = var :hero_x, 112 # where the hero stands in the room, in the room's own pixels
    y = var :hero_y, 72
    widest = var :widest, 240 - HERO # how far the hero can walk in this room, each way
    deepest = var :deepest, 160 - HERO
    view_x = var :view_x, 0 # the top-left of the view, in the room's pixels
    view_y = var :view_y, 0

    game_loop do
      held(:left).then  { x.sub! SPEED }
      held(:right).then { x.add! SPEED }
      held(:up).then    { y.sub! SPEED }
      held(:down).then  { y.add! SPEED }
      x.clamp! 0, widest
      y.clamp! 0, deepest

      # Down through the cabin door: out into the meadow, in front of the cabin.
      ((room == 0) & (y >= deepest - 8) & (x >= (14 * 8) - 8) & (x <= 15 * 8)).then do
        room.set! 1
        x.set! OUTSIDE_DOOR[0]
        y.set! OUTSIDE_DOOR[1]
        widest.set! (COLS * 8) - HERO
        deepest.set! (ROWS * 8) - HERO
      end
      # Up into the cabin's door in the meadow: back inside.
      ((room == 1) & (y <= (46 * 8) - 4) & (x >= (53 * 8) - 8) & (x <= 54 * 8)).then do
        room.set! 0
        x.set! INSIDE_DOOR[0]
        y.set! INSIDE_DOOR[1]
        widest.set! 240 - HERO
        deepest.set! 160 - HERO
      end

      # The view keeps the hero in the middle of the screen, and stops at the room's
      # edges: past them there is nothing to show.
      view_x.set! x - (120 - (HERO / 2))
      view_y.set! y - (80 - (HERO / 2))
      view_x.clamp! 0, widest + HERO - 240
      view_y.clamp! 0, deepest + HERO - 160

      world.show_map room
      world.scroll_to view_x, view_y
      hero.move_to x - view_x, y - view_y
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Meadow::GAME.write_if_main

# frozen_string_literal: true

# The world you swim in: three of the dive's four background layers, and the surface of
# the sea running across them.
#
# The far CLIFF is a dark rock face with nothing else on it. The REEF in front of it is
# sky above the waterline — with the sun in it — and sparse rock and kelp below, so the
# cliff shows through the gaps. And in FRONT of everything that moves there is the WATER.
#
# The water is the interesting layer three times over.
#
# It is see-through, so what is behind it shows through it: the reef, the cliff, and the
# diver. The console mixes the two as it draws each line, so it costs the same as a solid
# sheet however much is on screen.
#
# It is in front of the diver, which is the arrangement a picture cannot fall into by
# accident — scenery is normally behind everything that moves. Saying it is one line, the
# `layers` line in examples/dive.rb, where :surface comes after :swimmers.
#
# And it STOPS at the surface. Above the waterline its cells are empty, so there is
# nothing there to see through and what is behind draws plain. Swim up until your head
# comes out and the head is drawn in its own colours while the rest of you is still
# under water — one sprite, half of it blended and half of it not, and nothing in the
# program says a word about where the line is. The map says it.
#
# The cliff moves half as far as the reef does, which is the whole of the parallax: near
# things pass faster than far ones, and that is what tells you that you are moving at all
# in water with no landmarks. The reef keeps the same pace as the water, because those two
# share a waterline and it would come apart if they did not.
module Dive
  class Sea
    ACROSS = 32 # cells; 256 pixels, a little wider than the screen
    DOWN = 64   # cells; 512 pixels, deeper than the dive goes

    # The cell row the sea's surface runs along, in every map that has one.
    SURFACE_ROW = 6

    # The sun, as a block of four cells in the sky. Four because a disc drawn in 8-pixel
    # cells needs its corners rounded off, and a corner is a tile.
    SUN_COL = 14
    SUN_ROW = 2

    # How much of what is behind the water shows through it: 0 solid, 100 invisible.
    SEE_THROUGH = 58

    # How fast the water itself slides sideways, which is the current.
    DRIFT = 1

    # Which quarter of the sun this cell is, or nil for plain sky.
    def self.sun_quarter(row, col)
      down = row - SUN_ROW
      across = col - SUN_COL
      return nil unless down.between?(0, 1) && across.between?(0, 1)

      %w[1 2 3 4][(down * 2) + across]
    end

    # The far cliff: a dark face with paler flecks, opaque everywhere because nothing is
    # behind it, and the same all the way down so its wrap never shows.
    CLIFF = (0...DOWN).map do |r|
      (0...ACROSS).map { |c| ((r * 5) + (c * 3)) % 9 == 0 ? "o" : "." }.join
    end.freeze

    # The reef: sky with the sun in it above the waterline, then rock and kelp with gaps
    # the cliff shows through.
    REEF = (0...DOWN).map do |r|
      (0...ACROSS).map do |c|
        next(sun_quarter(r, c) || ".") if r < SURFACE_ROW
        next "k" if (c % 7).zero? && (r % 11) > 3 # a stand of kelp
        next "#" if ((r * 3) + (c * 7)) % 13 < 2  # a rock

        " "
      end.join
    end.freeze

    # The water: empty above the surface, the surface itself, then open water. The empty
    # cells are what lets a diver's head come out.
    WATER = (0...DOWN).map do |r|
      (0...ACROSS).map do |c|
        next " " if r < SURFACE_ROW
        next "=" if r == SURFACE_ROW

        ((r * 2) + c) % 5 == 0 ? "~" : "-"
      end.join
    end.freeze

    private_class_method :sun_quarter

    def initialize(build)
      @build = build
      declare_tiles
      @cliff = build.layer(:deep) { build.background :cliff, tiles: :rockface, map: CLIFF }
      @reef = build.layer(:reef) { build.background :reef, tiles: :reef, map: REEF }
      @water = build.layer(:surface, transparency: SEE_THROUGH) do
        build.background :water, tiles: :sea, map: WATER
      end
      @current = build.var(:current, 0) # how far the water has slid sideways
    end

    # Where the top of the sea is on the screen right now, for anything that must not be
    # put above it. It stops at the top of the screen, since past that the surface is
    # somewhere overhead and out of sight.
    def surface_on_screen(depth) = (-depth + (SURFACE_ROW * 8)).clamp(0, SURFACE_ROW * 8)

    # Put the scenery where this depth says. Every layer is told where to be rather than
    # nudged along, so none of them can drift out of step with the number they follow.
    def follow(depth)
      @current.add! DRIFT
      @cliff.scroll_to 0, depth / 2
      @reef.scroll_to 0, depth
      @water.scroll_to @current, depth
    end

    private

    def declare_tiles
      declare_rock
      declare_sky
      declare_water

      @build.tiles :rockface, "." => :stone, "o" => :cracked_stone
      @build.tiles :reef, "." => :sky, "#" => :boulder, "k" => :kelp,
                          "1" => :sun_nw, "2" => :sun_ne, "3" => :sun_sw, "4" => :sun_se
      @build.tiles :sea, "=" => :surface_line, "-" => :swell, "~" => :dapple
    end

    def declare_rock
      @build.image(:stone, "." => Ink::WALL, "o" => Ink::WALL_FLECK) do
        <<~ART
          ........
          ..o.....
          ........
          .....o..
          ........
          ...o....
          ........
          ......o.
        ART
      end
      @build.image(:cracked_stone, "." => Ink::WALL, "o" => Ink::WALL_FLECK) do
        <<~ART
          ...oo...
          ..o..o..
          .o....o.
          o......o
          .o....o.
          ..o..o..
          ...oo...
          ........
        ART
      end
      @build.image(:boulder, "#" => Ink::ROCK, "'" => Ink::ROCK_LIT) do
        <<~ART
          ''''''''
          ########
          ########
          ########
          ########
          ########
          ########
          ########
        ART
      end
      @build.image(:kelp, "." => :transparent, "|" => Ink::KELP, ":" => Ink::KELP_DARK) do
        <<~ART
          ...:|...
          ..:||...
          ..:|:...
          ...||:..
          ...:|:..
          ..:||...
          ..:|:...
          ...||:..
        ART
      end
    end

    # The sky above the waterline, and the sun standing in it. The sun is four tiles
    # because a disc drawn on an 8-pixel grid needs its corners rounding off.
    def declare_sky
      @build.image(:sky, "." => Ink::SKY, "'" => Ink::SKY_HIGH) do
        <<~ART
          ........
          ....'...
          ........
          ........
          ..'.....
          ........
          ........
          ......'.
        ART
      end
      quarters = { sun_nw: <<~NW, sun_ne: <<~NE, sun_sw: <<~SW, sun_se: <<~SE }
        .....sss
        ...ssSSS
        ..ssSSSS
        .ssSSSSS
        .sSSSSSS
        ssSSSSSS
        sSSSSSSS
        sSSSSSSS
      NW
        sss.....
        SSSss...
        SSSSss..
        SSSSSss.
        SSSSSSs.
        SSSSSSss
        SSSSSSSs
        SSSSSSSs
      NE
        sSSSSSSS
        sSSSSSSS
        ssSSSSSS
        .sSSSSSS
        .ssSSSSS
        ..ssSSSS
        ...ssSSS
        .....sss
      SW
        SSSSSSSs
        SSSSSSSs
        SSSSSSss
        SSSSSSs.
        SSSSSss.
        SSSSss..
        SSSss...
        sss.....
      SE
      quarters.each do |name, art|
        @build.image(name, "." => Ink::SKY, "s" => Ink::SUN_WEDGE, "S" => Ink::SUN) { art }
      end
    end

    def declare_water
      # The surface seen from below and from the side at once: bright where the light
      # catches it, and the one row of the map that says where the air stops.
      @build.image(:surface_line, "=" => Ink::WATER_SKIN, "-" => Ink::WATER_LIT, "~" => Ink::WATER) do
        <<~ART
          ========
          --------
          ~-~~-~~-
          ~~~~~~~~
          ~~-~~~-~
          ~~~~~~~~
          ~-~~~~~~
          ~~~~-~~~
        ART
      end
      @build.image(:swell, "-" => Ink::WATER, "~" => Ink::WATER_LIT) do
        <<~ART
          --------
          -~~-----
          --------
          -----~~-
          --------
          ---~~---
          --------
          ------~~
        ART
      end
      @build.image(:dapple, "-" => Ink::WATER, "~" => Ink::WATER_LIT) do
        <<~ART
          -~~--~~-
          ~--~~--~
          --~~~~--
          -~~--~~-
          ~--~~--~
          --~~~~--
          -~~--~~-
          ~--~~--~
        ART
      end
    end
  end
end

# frozen_string_literal: true

# The air gauge: a row of bars in a panel, going out one at a time as the tank empties.
#
# It is a BACKGROUND, and it empties by changing one of its cells — `set_tile` — not by
# redrawing anything. That is the shape almost every panel in a real game has: a heart
# row, an ammunition count, a key ring. Each is a handful of cells in a grid that
# otherwise never changes, and the alternative is spending a sprite on every bar out of
# the 128 the console draws at once.
#
# It is also the frontmost layer, IN FRONT of the see-through water. So the world behind
# the water is seen through it and the gauge is not — which is what you want from a panel
# and is nothing more than where its name sits on the `layers` line.
module Dive
  class Gauge
    CELLS = 32 # the map's size; almost all of it is blank, and a blank cell shows nothing

    BARS = 10  # how many bars of air the tank holds
    COL = 2    # the cell the first bar sits in
    ROW = 2

    # How long one bar of air lasts at rest, and so how long a full tank does: ten
    # seconds of easy breathing, and half that as deep as you can go.
    PER_BAR = 60
    FULL = BARS * PER_BAR

    # The panel: a blank sheet with a casing round a row of bars. Everything outside it is
    # a blank cell, so the water and the dive show through the rest of the screen.
    PANEL = (0...CELLS).map do |r|
      (0...CELLS).map do |c|
        next "#" if (r == ROW - 1 || r == ROW + 1) && c.between?(COL - 1, COL + BARS)
        next "#" if r == ROW && (c == COL - 1 || c == COL + BARS)
        next "|" if r == ROW && c.between?(COL, COL + BARS - 1)

        " "
      end.join
    end.freeze

    def initialize(build)
      @build = build
      declare_tiles
      @panel = build.layer(:panel) { build.background :gauge, tiles: :meter, map: PANEL }
      @air = build.var(:air, FULL)
      # How many bars are lit right now. The gauge is kept in step with the air by
      # changing ONE cell whenever this disagrees with the air, rather than by writing
      # every bar every frame.
      @lit = build.var(:lit, BARS)
    end

    # How much air is left, for the game to read.
    attr_reader :air

    # Breathing out, and breathing in at the surface. Neither one tidies the number up —
    # `update` below holds it inside the tank once, however many places spent from it.
    def spend(breaths)
      @air.sub! breaths
    end

    def refill(breaths)
      @air.add! breaths
    end

    def empty? = @air == 0

    # A fresh tank. The bars themselves come back one a frame, from `update` below, which
    # is why there is nothing to redraw here.
    def reset
      @air.set! FULL
    end

    # Move the picture one bar toward what the tank actually holds. One cell a frame is
    # enough because the air moves by a breath a frame, and it means the gauge costs a
    # comparison on every frame where nothing changed.
    def update
      @air.clamp! 0, FULL
      wanted = @air / PER_BAR
      (wanted < @lit).then do
        @panel.set_tile((COL - 1) + @lit, ROW, "-")
        @lit.sub! 1
      end
      (wanted > @lit).then do
        @lit.add! 1
        @panel.set_tile((COL - 1) + @lit, ROW, "|")
      end
    end

    private

    def declare_tiles
      @build.image(:casing, "#" => Ink::PANEL, "=" => Ink::PANEL_LIT) do
        <<~ART
          ========
          ########
          ########
          ########
          ########
          ########
          ########
          ########
        ART
      end
      @build.image(:air_left, "|" => Ink::AIR, ":" => Ink::AIR_DARK) do
        <<~ART
          ::::::::
          ||||||||
          ||||||||
          ||||||||
          ||||||||
          ||||||||
          ||||||||
          ::::::::
        ART
      end
      @build.image(:air_gone, "-" => Ink::SPENT, ":" => Ink::SPENT_DARK) do
        <<~ART
          ::::::::
          --------
          --------
          --------
          --------
          --------
          --------
          ::::::::
        ART
      end

      # Every tile the tileset names is shipped whether the map used it or not, so the
      # spent bar can be drawn here and only ever appear once the air starts going.
      @build.tiles :meter, "#" => :casing, "|" => :air_left, "-" => :air_gone
    end
  end
end

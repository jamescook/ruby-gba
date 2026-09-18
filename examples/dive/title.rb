# frozen_string_literal: true

# The title screen: the surface of the sea, seen from below.
#
# A disc of sunlight turns and swells overhead while two sheets of light shafts drift
# past it at different speeds. That is the console's MIXED arrangement — two background
# layers that scroll beside one that turns and resizes — and this file never says so. A
# background turns because something turns it, and `sun.rotate` on the line below is the
# whole of the asking.
#
# What makes it worth a title screen rather than a test is what happens next: press START
# and the game hands over to a screen with FOUR scrolling layers and nothing turning,
# which is the console's other arrangement. One cartridge, both — because the console is
# told which one it is in as each scene takes over, and each scene's backgrounds are
# declared inside it.
#
# The disc has wedges rather than being plain, for a reason worth stating: a disc turning
# about its own middle is rotationally symmetric, so a plain one turns invisibly. The
# wedges are what let you see it move at all.
module Dive
  class Title
    # A layer that turns has to have a square map — it pivots about its own middle — and
    # 32 cells of 8 pixels is 256 square, comfortably more than the screen.
    CELLS = 32

    # The cell the disc is centred on. At rest the layer sits over the screen one for one,
    # so this is the middle of the screen in cells, and the disc pivots where it is drawn.
    SUN_COL = 15
    SUN_ROW = 10
    SUN_CELLS = 3 # how far the disc reaches, in cells
    WEDGES = 6    # how many light and dark segments it is cut into

    TURN_PER_FRAME = 2 # degrees

    # How far the disc breathes either side of the size it was drawn, and how fast.
    SMALLEST = 0.75
    BIGGEST = 1.30
    BREATH = 0.01

    # How fast each sheet of shafts drifts across, in pixels a frame. Two speeds is what
    # makes the water read as having depth rather than as one flat picture sliding.
    FAR_DRIFT = 1
    NEAR_DRIFT = 2

    # THE NEAR SHAFTS SHIMMER, which is light on moving water and is one word to ask for:
    # the layer is told to draw from a different list of colours, and the lists differ only
    # in how bright the shafts are. Nothing is redrawn and no cell of the map changes — the
    # console draws every pixel by looking a colour up in a table, so moving four entries of
    # that table moves every pixel of the layer at once, however much of it is on screen.
    #
    # The FAR sheet holds still through all of it, though both sheets are drawn from the
    # same tiles: a layer that can be recoloured is given colours nobody else reads, so the
    # shimmer reaches this one and stops there.
    #
    # Each list is the tiles' own list with the two shaft colours moved, which is what says
    # the water behind them holds still: a swap goes by PLACE, so an entry left as it was
    # draws exactly as it did.
    #
    # The steps are named here so that the list of them and the counter that walks it cannot
    # drift apart, and how long each is held is a SHIFT, so the counter is divided for free.
    SHIMMER = %i[shimmer0 shimmer1 shimmer2 shimmer3].freeze
    SHIMMER_HELD = 3 # eight frames a step

    # The far sheet: open water everywhere, with shafts of light leaning through it. It is
    # the backmost layer of this screen, so it has no holes — there is nothing behind it.
    FAR = (0...CELLS).map do |r|
      (0...CELLS).map { |c| ((c + (r / 2)) % 8).zero? ? "|" : "." }.join
    end.freeze

    # The near sheet: nothing but shafts, leaning the other way. A blank cell is a hole
    # the layer behind shows through, which is what makes two sheets read as two.
    NEAR = (0...CELLS).map do |r|
      (0...CELLS).map { |c| ((c - (r / 3)) % 16) == 4 ? "|" : " " }.join
    end.freeze

    # The disc, cut into alternating wedges so that turning it is visible.
    SUN = (0...CELLS).map do |r|
      (0...CELLS).map do |c|
        across = c - SUN_COL
        down = r - SUN_ROW
        next " " if (across * across) + (down * down) > SUN_CELLS * SUN_CELLS

        wedge = (Math.atan2(down, across) / Math::PI * (WEDGES / 2.0)).floor
        wedge.even? ? "O" : "o"
      end.join
    end.freeze

    def initialize(build)
      @build = build
      declare_tiles
      declare_shimmer

      # The stack, back to front: the far shafts, the near ones, then the disc in front of
      # both. Only the disc turns, and only because `update` below turns it.
      @far = build.layer(:shafts_far) { build.background :shafts_far, tiles: :shafts, map: FAR }
      @near = build.layer(:shafts_near) { build.background :shafts_near, tiles: :shafts, map: NEAR }
      @sun = build.layer(:sun) { build.background :sun, tiles: :disc, map: SUN }

      build.layer(:name) do
        build.draw_text "A DIVE", :center, 108, :white
        build.draw_text "PRESS START", :center, 128, :white, font: :tiny
      end

      @swelling = build.var(:swelling, 1) # 1 while the disc is growing, 0 while it shrinks
      @shimmering = build.var(:shimmering, 0) # ...and how far through the shafts' cycle we are
    end

    def update
      @sun.rotate(@sun.angle + TURN_PER_FRAME)
      breathe
      @far.scroll_by FAR_DRIFT, 0
      @near.scroll_by NEAR_DRIFT, 0
      shimmer
    end

    private

    # Walk the near sheet through its four lists of colours, a new one every eight frames and
    # round again. One counter, shifted to slow it and masked to wrap it — no test per step,
    # and nothing to put back when it comes round.
    def shimmer
      @shimmering.add! 1
      @near.draw_with(SHIMMER, showing: (@shimmering >> SHIMMER_HELD) & (SHIMMER.length - 1))
    end

    # In and out, for ever: turn round at each end and ease toward the other one.
    def breathe
      (@sun.scale >= BIGGEST).then { @swelling.set! 0 }
      (@sun.scale <= SMALLEST).then { @swelling.set! 1 }
      (@swelling == 1).then { @sun.scale.approach! BIGGEST, BREATH }
                      .else { @sun.scale.approach! SMALLEST, BREATH }
    end

    # The water's own colours, in the order the shimmer lists follow: a swap goes by PLACE,
    # so every list below names these same places and changes only the two the shafts are
    # drawn in. Both tiles of the sheet are given it, because a list is matched against the
    # one list a layer's tiles share.
    def water_colors = [:transparent, Ink::SURFACE, Ink::SURFACE_SPOT, Ink::SHAFT, Ink::SHAFT_EDGE]

    # ...and the four the near sheet walks through: the shafts brightening and going back,
    # with the water behind them left exactly as it was drawn.
    def declare_shimmer
      steps = [[Ink::SHAFT, Ink::SHAFT_EDGE],
               [Ink::RGB.rgb(16, 24, 31), Ink::RGB.rgb(9, 17, 28)],
               [Ink::RGB.rgb(19, 26, 31), Ink::RGB.rgb(11, 19, 29)],
               [Ink::RGB.rgb(16, 24, 31), Ink::RGB.rgb(9, 17, 28)]]
      SHIMMER.each_with_index do |name, step|
        @build.colors name, water_colors.first(3) + steps[step]
      end
    end

    def declare_tiles
      @build.image(:open_water, "." => Ink::SURFACE, "," => Ink::SURFACE_SPOT, colors: water_colors) do
        <<~ART
          ........
          ...,....
          ........
          ......,.
          ........
          .,......
          ........
          ....,...
        ART
      end
      # A shaft has VERTICAL structure and a soft edge, so a sheet of them drifting
      # sideways reads as light moving rather than as a wall sliding.
      @build.image(:light_shaft, "." => Ink::SURFACE, "|" => Ink::SHAFT, ":" => Ink::SHAFT_EDGE,
                                 colors: water_colors) do
        <<~ART
          ..:||:..
          ..:||:..
          .::||:..
          ..:||::.
          ..:||:..
          .::||:..
          ..:||:..
          ..:||::.
        ART
      end
      @build.image(:sun_lit, "O" => Ink::SUN) { "OOOOOOOO\n" * 8 }
      @build.image(:sun_dim, "o" => Ink::SUN_WEDGE) { "oooooooo\n" * 8 }

      @build.tiles :shafts, "." => :open_water, "|" => :light_shaft
      @build.tiles :disc, "O" => :sun_lit, "o" => :sun_dim
    end
  end
end

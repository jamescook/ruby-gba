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
    end

    def update
      @sun.rotate(@sun.angle + TURN_PER_FRAME)
      breathe
      @far.scroll_by FAR_DRIFT, 0
      @near.scroll_by NEAR_DRIFT, 0
    end

    private

    # In and out, for ever: turn round at each end and ease toward the other one.
    def breathe
      (@sun.scale >= BIGGEST).then { @swelling.set! 0 }
      (@sun.scale <= SMALLEST).then { @swelling.set! 1 }
      (@swelling == 1).then { @sun.scale.approach! BIGGEST, BREATH }
                      .else { @sun.scale.approach! SMALLEST, BREATH }
    end

    def declare_tiles
      @build.image(:open_water, "." => Ink::SURFACE, "," => Ink::SURFACE_SPOT) do
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
      @build.image(:light_shaft, "." => Ink::SURFACE, "|" => Ink::SHAFT, ":" => Ink::SHAFT_EDGE) do
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

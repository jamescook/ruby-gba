# frozen_string_literal: true

# The diver, and the bubbles that come off them.
#
# The diver is an ordinary sprite. What is not ordinary is where it sits: BEHIND the
# water, because :swimmers comes before :surface on the `layers` line in examples/dive.rb.
# Scenery is normally behind everything that moves, so this is the one arrangement a
# picture cannot fall into by accident — and nothing in this file mentions it.
#
# It is drawn facing right, and faces left by `mirror`, which is the same picture the
# other way round. The console reverses a sprite for nothing, so the left-facing pose
# keeps no pixels of its own: half the sprite memory of a diver drawn both ways, and half
# the art.
#
# The bubbles are a pool: one line says "up to this many of a thing with these fields",
# and `each` runs the same behaviour over whichever are alive. They are in the same layer
# as the diver, so they are under the water too — which is right, because they have not
# reached the surface yet.
module Dive
  class Diver
    SIZE = 16
    SPEED = 2

    # Where the diver sits on screen while there is water above them. Swimming up and down
    # moves the WORLD past this point; it is only at the very top, where the world has run
    # out of sea to show, that the diver climbs off it and breaks the surface.
    STARTS_AT = [112, 72].freeze
    RESTING_Y = 72

    BUBBLES = 12      # at once
    BUBBLE_RISE = 2   # pixels a frame
    EVERY = 14        # frames between one bubble and the next
    FROM_BACK = 2     # where on the diver they come off

    SUIT = <<~ART
      ................
      .............oo.
      ...........#oo#.
      .....##########.
      ..##############
      .###############
      .###############
      ..##############
      =====###########
      =====####.......
      ..###...........
      .###............
      ###.............
      .###............
      ..##............
      ................
    ART

    def initialize(build)
      @build = build
      declare_art

      @diver = build.layer(:swimmers) do
        build.sprite :diver, at: STARTS_AT,
                             facing: { right: :diver_right, left: build.mirror(:diver_right) }
      end
      @bubbles = build.layer(:swimmers) do
        build.pool :bubble, x: 0, y: 0, capacity: BUBBLES, image: :bubble
      end
      @since_last = build.var(:since_last, 0)
    end

    # The sprite itself, for anything that needs to know where the diver is.
    attr_reader :diver

    # +above_water+ is how far the diver has climbed past the top of the sea: 0 while
    # there is still water above them, and negative once they are breaking the surface.
    # +surface+ is where the top of the sea is on screen, which is what the bubbles are
    # measured against — they come off a diver who is under it and stop when they reach it.
    def update(above_water, surface)
      @build.held(:left).then { @diver.move :left, by: SPEED }
      @build.held(:right).then { @diver.move :right, by: SPEED }
      @diver.y.set! above_water + RESTING_Y
      @diver.clamp_to_screen
      breathe_out(surface)
      rise(surface)
    end

    def reset
      @diver.move_to(*STARTS_AT)
      @bubbles.each(&:remove)
    end

    private

    # A bubble every so often, from the diver's tank — and only while the tank is under
    # water, because a diver with their head in the air is breathing it rather than
    # letting it go. The pool quietly ignores a spawn it has no room for, so there is no
    # test here for being full.
    def breathe_out(surface)
      @since_last.add! 1
      ((@since_last >= EVERY) & (@diver.y > surface)).then do
        @since_last.set! 0
        @bubbles.spawn x: @diver.x + FROM_BACK, y: @diver.y
      end
    end

    # Up, and gone when they reach the top of the sea. Deep down the surface is somewhere
    # overhead and this reads as the top of the screen, which is the same test.
    def rise(surface)
      @bubbles.each do |bubble|
        bubble.y.sub! BUBBLE_RISE
        (bubble.y < surface).then { bubble.remove }
      end
    end

    def declare_art
      @build.image(:diver_right, "." => :transparent, "#" => Ink::SUIT,
                                 "o" => Ink::MASK, "=" => Ink::TANK) { SUIT }
      @build.image(:bubble, "." => :transparent, "o" => Ink::BUBBLE, "O" => Ink::BUBBLE_LIT) do
        <<~ART
          ..ooo...
          .oOO.o..
          oO....o.
          o.....o.
          o.....o.
          .o...o..
          ..ooo...
          ........
        ART
      end
    end
  end
end

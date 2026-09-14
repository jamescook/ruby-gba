# frozen_string_literal: true

# The player's ship and its single shot — one part of the shmup, in its own file.
#
# It's a plain Ruby object. The only thing that makes it "part of the game" is that it
# takes the build (what RubyGBA.build hands your block as `self`) and calls the DSL
# verbs on it — build.sprite, build.held, build.var — the same verbs you'd write at the
# top level, just spelled `build.` here because inside this object `self` is the Player,
# not the build. No base class, no magic.
module Shmup
  class Player
    SPEED = 2
    SHOT_SPEED = 4
    NOSE = 6 # where the shot leaves the ship (its horizontal centre, roughly)
    SAFE = 60 # frames after losing a ship that the next one cannot be hit

    # `#` is the hull and `=` the cockpit.
    SHIP = <<~ART
      .......##.......
      .......##.......
      ......####......
      ......####......
      .....######.....
      .....######.....
      ....###==###....
      ....###==###....
      ...####==####...
      ...####==####...
      ..############..
      ..############..
      .##############.
      .##############.
      ################
      ################
    ART

    SHOT = <<~ART
      ..####..
      ..####..
      ..####..
      ..####..
      ..####..
      ..####..
      ..####..
      ..####..
    ART

    def initialize(build)
      @build = build
      # The ship's own list of colours, in order. Other lists swap them by place, so the
      # warm pulse's second colour lands on the hull and its third on the cockpit.
      build.image(:ship, "." => :transparent, "#" => :cyan, "=" => :white,
                         colors: [:transparent, :cyan, :white]) { SHIP }
      build.image(:shot, "." => :transparent, "#" => :white) { SHOT }
      @ship = build.sprite(:ship, at: [112, 132])
      @shot = build.sprite(:shot, at: [0, 0], shown: false)
      @shot_live = build.var(:shot_live, 0) # 1 while a shot is in flight
      @safe = build.var(:ship_safe, 0)      # frames left that the ship cannot be hit
    end

    # Other parts test collisions against these, and read where the ship is.
    attr_reader :ship, :shot, :shot_live

    # Whether anything can hurt the ship right now — a test, for the parts that hurt it.
    def hittable = (@safe <= 0)

    # A ship was lost: the next one cannot be hit for a moment.
    def hurt
      @safe.set! SAFE
    end

    # Steer, keep on screen, fire, and fly the shot — one frame's worth.
    def update
      @build.held(:left).then  { @ship.move :left,  by: SPEED }
      @build.held(:right).then { @ship.move :right, by: SPEED }
      @ship.clamp_to_screen # keep the ship on screen — it works out its own size

      glow_while_safe
      fire_when_ready
      fly_the_shot
    end

    # Let an enemy that got shot take the shot out of play, so the player can fire again.
    def reclaim_shot
      @shot.hide
      @shot_live.set! 0
    end

    # Back to the start: ship centred, no shot in flight, and hittable.
    def reset
      @ship.move_to 112, 132
      @safe.set! 0
      reclaim_shot
    end

    private

    # While the ship cannot be hit it pulses warm, and then it is its own colours again.
    # The pulse steps every four frames, so `(@safe >> 2) & 3` walks through the four
    # lists and round again; the ship's picture is the same picture throughout.
    def glow_while_safe
      (@safe > 0).then do
        @safe.sub! 1
        @ship.draw_with WARM, showing: (@safe >> 2) & 3
      end.else do
        @ship.draw_with :own
      end
    end

    def fire_when_ready
      (@shot_live == 0).then do
        @build.pressed(:a).then do
          @shot.move_to @ship.x + NOSE, @ship.y - 6
          @shot.show
          @shot_live.set! 1
        end
      end
    end

    def fly_the_shot
      (@shot_live == 1).then do
        @shot.move 0, -SHOT_SPEED # travel up
        @shot.above_top?.then { reclaim_shot } # gone off the top: ready to fire again
      end
    end
  end
end

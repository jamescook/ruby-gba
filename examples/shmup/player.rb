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

    SHIP = <<~ART
      .......##.......
      .......##.......
      ......####......
      ......####......
      .....######.....
      .....######.....
      ....########....
      ....########....
      ...##########...
      ...##########...
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
      build.image(:ship, "." => :transparent, "#" => :cyan) { SHIP }
      build.image(:shot, "." => :transparent, "#" => :white) { SHOT }
      @ship = build.sprite(:ship, at: [112, 132])
      @shot = build.sprite(:shot, at: [0, 0], shown: false)
      @shot_live = build.var(:shot_live, 0) # 1 while a shot is in flight
    end

    # Other parts test collisions against these, and read where the ship is.
    attr_reader :ship, :shot, :shot_live

    # Steer, keep on screen, fire, and fly the shot — one frame's worth.
    def update
      @build.held(:left).then  { @ship.move :left,  by: SPEED }
      @build.held(:right).then { @ship.move :right, by: SPEED }
      @ship.x.clamp 0, 240 - 16 # the ship is 16 wide

      fire_when_ready
      fly_the_shot
    end

    # Let an enemy that got shot take the shot out of play, so the player can fire again.
    def reclaim_shot
      @shot.hide
      @shot_live.set 0
    end

    # Back to the start: ship centred, no shot in flight.
    def reset
      @ship.move_to 112, 132
      reclaim_shot
    end

    private

    def fire_when_ready
      (@shot_live == 0).then do
        @build.pressed(:a).then do
          @shot.move_to @ship.x + NOSE, @ship.y - 6
          @shot.show
          @shot_live.set 1
        end
      end
    end

    def fly_the_shot
      (@shot_live == 1).then do
        @shot.move 0, -SHOT_SPEED # travel up
        (@shot.y < 0).then { reclaim_shot } # gone off the top: ready to fire again
      end
    end
  end
end

# frozen_string_literal: true

# The enemies — another part of the game, in its own file. A POOL of them: one
# declaration says "up to this many of a thing with these fields", and `each` runs the
# same behaviour over whichever are alive. Nothing here keeps parallel arrays of
# positions and states that could fall out of step, because there is nothing to keep.
#
# They also FLAP, and turn to face the ship they are diving at. `facing:` gives the pool
# a picture per direction and a list of frames for each, and `rate:` says how fast to run
# through them — the same words a single `sprite` takes, spelled the same way. What is
# different is that the direction and the place in the cycle belong to each INSTANCE: one
# test written once leaves three enemies leaning three different ways, and one respawned
# just now starts its flap where it starts rather than in step with the rest.
#
# Its per-frame entry point is `update`, the convention every collaborator follows. It
# takes the player and the HUD because that's who it interacts with — a shot that lands
# scores and frees the shot; a ship it touches costs a life. Plain method calls between
# plain objects.
module Shmup
  class Enemies
    LIVE = 3   # how many are in the air at once
    SPEED = 1
    SIZE  = 16

    # Two frames of a flap, and a mirrored pair so an enemy can lean the way it drifts.
    # A wing down...
    WINGS_DOWN = <<~ART
      ..############..
      .##############.
      ################
      ##.##########.##
      ##.##########.##
      ################
      ################
      ################
      ################
      ################
      .##############.
      ..##########.##.
      ...########.....
      ..#.######.#....
      .##..####..##...
      ###...##...###..
    ART

    # ...and a wing up: the same body with the tips raised.
    WINGS_UP = <<~ART
      ###..######..###
      .##.########.##.
      ..############..
      ..#.########.#..
      ..#.########.#..
      ..############..
      ..############..
      .##############.
      ################
      ################
      ################
      ..##########.##.
      ...########.....
      ....######......
      ....######......
      .....####.......
    ART

    def initialize(build)
      @build = build
      build.image(:flap_l1, "." => :transparent, "#" => :red) { WINGS_DOWN }
      build.image(:flap_l2, "." => :transparent, "#" => :red) { WINGS_UP }
      build.image(:flap_r1, "." => :transparent, "#" => :orange) { WINGS_DOWN }
      build.image(:flap_r2, "." => :transparent, "#" => :orange) { WINGS_UP }

      # One line for the whole flock: the fields each enemy carries, how many can be in
      # the air, and the pictures they show. `drift` is which way this one is leaning,
      # which is also which pair of pictures it draws from.
      @enemies = build.pool :enemy, x: 0, y: 0, capacity: LIVE, rate: 8,
                                    facing: { left: %i[flap_l1 flap_l2], right: %i[flap_r1 flap_r2] }
      LIVE.times { |i| @enemies.spawn x: 36 + (i * 72), y: i * 52 }
    end

    def update(player, hud)
      @enemies.each do |enemy|
        enemy.y.add SPEED                            # drift down
        # Turn to face the ship it is diving at. `face` is the same verb a single sprite
        # takes, and each instance holds its own direction — so this one test, written
        # once, leaves three enemies leaning three different ways in the same frame.
        (enemy.x < player.ship.x).then { enemy.face :right }.else { enemy.face :left }
        enemy.below_bottom?.then { respawn enemy }   # off the bottom: come round again

        # A live shot that lands: score it, take the shot out of play, send this one back.
        (player.shot_live == 1).then do
          player.shot.overlaps?(enemy).then do
            hud.score_up
            player.reclaim_shot
            respawn enemy
          end
        end

        # Touched the ship: cost a life, send this one back.
        player.ship.overlaps?(enemy).then do
          hud.hit
          respawn enemy
        end
      end
    end

    # Back to the start: every slot empty, then the opening flock again.
    def reset
      @enemies.each(&:remove)
      LIVE.times { |i| @enemies.spawn x: 36 + (i * 72), y: i * 52 }
    end

    private

    def respawn(enemy)
      enemy.x.set @build.rand(0..(240 - SIZE)) # a fresh column, back at the top
      enemy.y.set 0
    end
  end
end

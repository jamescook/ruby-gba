# frozen_string_literal: true

# The enemies — another part of the game, in its own file. A fixed few (no runtime
# pool yet; that's a later feature), each drifting down and coming round again. The
# `.each` runs at BUILD time, so it simply unrolls the same logic once per enemy into
# the game loop — a handful of independent enemies, no per-frame indexing.
#
# Its per-frame entry point is `update`, the convention every collaborator follows. It
# takes the player and the HUD because that's who it interacts with — a shot that lands
# scores and frees the shot; a ship it touches costs a life. Plain method calls between
# plain objects.
module Shmup
  class Enemies
    COUNT = 3
    SPEED = 1
    SIZE  = 16

    ENEMY = <<~ART
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

    def initialize(build)
      @build = build
      build.image(:enemy, "." => :transparent, "#" => :red) { ENEMY }
      build.seed 0xC0DE
      # Start them spread across the top, at staggered heights.
      @enemies = Array.new(COUNT) { |i| build.sprite(:enemy, at: [36 + (i * 72), i * 52]) }
    end

    def update(player, hud)
      @enemies.each do |enemy|
        enemy.move 0, SPEED                        # drift down
        (enemy.y > 160).then { respawn enemy }     # off the bottom: come round again

        # A live shot that lands: score it, take the shot out of play, send the enemy back.
        (player.shot_live == 1).then do
          player.shot.overlaps?(enemy).then do
            hud.score_up
            player.reclaim_shot
            respawn enemy
          end
        end

        # Touched the ship: cost a life, send the enemy back.
        player.ship.overlaps?(enemy).then do
          hud.hit
          respawn enemy
        end
      end
    end

    private

    def respawn(enemy)
      enemy.move_to @build.rand(0..(240 - SIZE)), 0 # a fresh column, back at the top
    end
  end
end

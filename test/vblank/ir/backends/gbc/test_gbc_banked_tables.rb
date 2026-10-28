# frozen_string_literal: true

require "test_helper"

# A SPRITE OF SEVERAL POSES WALKING MANY LISTS OF COLOURS keeps a row for every pose under every list,
# poses times lists, and a few such sprites fading through a screen's worth of lists come to more than
# the part of a Color cartridge always in view holds beside the game's code. Such a game is built
# with those rows in the cartridge's banks (GBC#build), read with their bank put in view, and plays as
# it does on the interpreter.
class TestGBCBankedTables < Minitest::Test
  SPRITES = 12
  POSES = 5
  LISTS = 50

  private def many_posed_sprites_walking_many_lists
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      LISTS.times { |s| colors :"fade#{s}", [:transparent, rgb(s % 32, 31 - (s % 32), 8), rgb(4, s % 32, 31 - (s % 32))] }
      poses = (0...POSES).map do |p|
        image :"ball#{p}", width: 8, height: 8, colors: :fade0, places: Array.new(64) { |i| 1 + (((i + p) % 8) / 4) }
        :"ball#{p}"
      end
      # Six to a row: a Color draws ten sprites on a row of the screen at most.
      balls = (0...SPRITES).map { |n| sprite :"ball_sprite#{n}", at: [8 + ((n % 6) * 16), 40 + ((n / 6) * 24)], frames: poses, rate: 2 }
      # A table the game reads, which the build keeps a note of beside the pose tables.
      steps = table :steps, (0...LISTS).map { |s| (s + 1) % LISTS }
      step = var :step, 0
      game_loop do
        step.set! steps[step]
        balls.each { |ball| ball.draw_with((0...LISTS).map { |s| :"fade#{s}" }, showing: step) }
      end
    end
    b.finalize_program
    b.program
  end

  def test_sprites_whose_pose_rows_do_not_fit_in_view_still_build_and_play
    game_player.run(many_posed_sprites_walking_many_lists, frames: 12)
  end
end

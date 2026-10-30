# frozen_string_literal: true

require "test_helper"
require "differential"

# A POOL DECLARED IN A SCENE, DRAWN AS THE GAME WALKS INTO THAT SCENE AND OUT AGAIN.
#
# A pool's things are put in the order they are drawn in only while its scene is up, since they
# show only then. So the first frame back in the scene has to be put in order and drawn from the
# same moment, and a frame on another scene must show none of them.
class TestPoolDrawnByScene < Minitest::Test
  include Differential

  # A title, and a playing scene whose pool of sparks has three live things that move. The game
  # walks between them by itself: the title until frame 6, play until frame 12, then the title
  # again.
  private def title_and_play
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:dot, "#" => :yellow) { "########\n" * 8 }
      t = var :t, 0
      where = var :where, 0
      scene(:title) { draw_text "TITLE", 10, 10, :white }
      scene :playing do
        sparks = pool :spark, x: 0, y: 0, capacity: 8, image: :dot
        (sparks.count == 0).then { 3.times { |n| sparks.spawn(x: 20 + (n * 30), y: 40 + (n * 8)) } }
        sparks.each { |spark| spark.x.add! 1 }
      end
      game_loop do
        t.add! 1
        (t == 6).then { where.set! 1 }
        (t == 12).then { where.set! 0 }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # On the title nothing of the pool is drawn; in play its three things are, where they stand.
  def test_the_pool_is_drawn_only_while_play_is_up
    seen = []
    i = game_player
    i.each_vblank { |frame| seen << [frame, i.sprites(:spark).size] }
    i.run(title_and_play, frames: 16)

    on_title = seen.select { |frame, _| frame < 6 || frame > 13 }.map(&:last).uniq
    in_play = seen.select { |frame, _| frame.between?(8, 11) }.map(&:last).uniq
    assert_equal [0], on_title, seen.inspect
    assert_equal [3], in_play, seen.inspect
  end

  # The picture is the interpreter's on each frame, across arriving in play and leaving it.
  def test_the_pool_is_drawn_the_same_on_every_lowering
    [4, 7, 8, 11, 13, 14].each { |f| assert_backends_agree(title_and_play, frames: f) }
  end
end

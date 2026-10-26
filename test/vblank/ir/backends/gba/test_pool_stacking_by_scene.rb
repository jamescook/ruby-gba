# frozen_string_literal: true

require "test_helper"

# A POOL DECLARED IN A SCENE IS PUT IN ITS DRAWING ORDER ONLY WHILE THAT SCENE IS UP.
#
# Before every frame each pool that draws has its live things copied into the order they are
# drawn in (oldest in front). A pool declared in a scene shows only while that scene is up, so
# on every other scene's frames the copy is work nobody sees — a copy per live thing, every
# frame, on a screen that draws none of them. That the picture is unchanged by this is
# test/vblank/builder/test_pool_drawn_by_scene.rb, which plays on every lowering.
class TestPoolStackingByScene < Minitest::Test
  STACKING = VBlank::Messages::MadeNames.make(:pool_stacking, pool: :spark)

  # A title, and a playing scene whose pool of sparks has three live things. The game walks
  # between them by itself: the title until frame 6, play until frame 12, then the title again.
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

  private def time_in_stacking(scene)
    rom = assemble_rom(title_and_play, name: "STACKS")
    line = VBlank::Diagnostics::Profiler.run(rom, scene: scene, frames: 10, picture: false)
                                         .lines.find { |l| l.name == STACKING }
    line ? line.samples : 0
  end

  def test_the_title_spends_nothing_putting_plays_pool_in_order
    assert_equal 0, time_in_stacking(:title)
  end

  def test_play_still_puts_its_pool_in_order
    assert_operator time_in_stacking(:playing), :>, 0
  end
end

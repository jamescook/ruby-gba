# frozen_string_literal: true

require "test_helper"

# What a Super Nintendo cartridge draws on a tiled screen is what the interpreter draws, pixel for
# pixel, after every pass (SNES::CheckedRun): its backgrounds — put up, scrolled, a cell changed, a
# map handed over — and its sprites, moving, off every edge and back. Colours are picked so that a
# tile drawn from the wrong palette or a sprite one row out shows as a pixel in the wrong place.
class TestSNESPicture < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_a_sprite_moving_off_every_edge_is_drawn_where_the_interpreter_draws_it
    run = checked(frames: 40) do
      screen :tiled
      image :ship, "." => :transparent, "r" => :red, "g" => :green, "b" => :blue, "w" => :white do
        <<~ART
          rrrrrrrrgggggggg
          r..............g
          r..wwww........g
          r..............g
          bbbbbbbbbbbbbbbb
        ART
      end
      ship = sprite :ship, at: [0, 0]
      x = var :x, -20
      y = var :y, -10
      game_loop do
        x.add! 7
        y.add! 6
        (x > 270).then { x.set! -30 }
        (y > 236).then { y.set! -12 }
        ship.move_to x, y
      end
    end

    refute_empty run.sprites
  end

  def test_several_sprites_overlap_the_later_one_in_front
    run = checked(frames: 12) do
      screen :tiled
      image(:block, "#" => :yellow) { "########\n" * 8 }
      image(:bar, "#" => :magenta) { "################\n" * 4 }
      a = sprite :block, at: [20, 20]
      b = sprite :bar, at: [16, 22]
      t = var :t, 0
      game_loop do
        t.add! 1
        a.move_to 20 + t, 20
        b.move_to 16, 22 + t
      end
    end

    assert_equal 2, run.sprites.length
  end

  def test_a_background_put_up_scrolled_changed_and_handed_another_map
    run = SNES::CheckedRun.new
    run.input_each_frame { |frame| frame == 5 ? [:a] : (frame == 9 ? [:b] : []) }
       .run(program_of do
         screen :tiled
         image :wall, "#" => :gray, "." => rgb(10, 3, 3) do
           "#.######\n" + ("########\n" * 6) + ".######.\n"
         end
         image :water, "~" => :blue, "=" => rgb(12, 12, 31) do
           "~~==~~~~\n" * 8
         end
         tiles :set, "#" => :wall, "~" => :water
         room = background :room, tiles: :set, map: {
           one: "##########\n#~~~~~~~~#\n#~~~##~~~#\n##########\n",
           two: "~~~~~~~~~~\n~########~\n~~~~~~~~~~\n~~~~~~~~~~\n"
         }
         x = var :x, 0
         game_loop do
           x.add! 3
           room.scroll_to x, x / 2
           pressed(:a).then { room.set_tile 2, 1, "#" }
           pressed(:b).then { room.show_map 1 }
         end
       end, frames: 14)

    assert_operator run[:x], :>, 0
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  def checked(frames: nil, &game)
    SNES::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end

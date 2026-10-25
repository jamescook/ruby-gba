# frozen_string_literal: true

require "test_helper"
require "differential"

# The test of test_sprite_cleared_field.rb whose game paints more colours into one 8×8 square of
# the screen than a Game Boy Color's square holds — a white field cleared to blue, a green wall and
# a red sprite, over the black the console starts with — so it plays on the Advance's runs alone.
class TestSpriteClearedFieldOnTheAdvance < Minitest::Test
  include Differential

  SIDE = 8
  BLOCK = ("########\n" * SIDE).freeze
  START = [40, 40].freeze
  ONE = SIDE * SIDE
  # The whole screen, in pixels, of the console this run plays the game on.
  private def field = RubyGBA::Console.described(game_console).screen_size.reduce(:*)

  # A white field with a red block sprite declared above the loop. The block is the game
  # loop's body, handed the sprite and a counter of the passes so far.
  private def field_program(&body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      clear_screen :white
      hero = sprite :block, at: START
      step = var :step, 0
      game_loop do
        instance_exec(hero, step, &body)
        step.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  # How many pixels of each colour the picture holds after +frames+ passes, once both
  # backends have been seen to draw the same picture.
  private def colors_after(prog, frames)
    oracle, console, = backend_pictures(prog, frames: frames, name: "SPRCLR")
    bad = mismatched_pixels(oracle, console)
    assert_empty bad.first(5), "the console drew a different picture at #{bad.length} pixels"
    %i[red white blue green].to_h { |color| [color, oracle.count(Color.resolve(color))] }
  end

  # The field is more than the clear: a wall painted after it, where the sprite stands. The
  # sprite is drawn over the wall and has to remember the wall, not the cleared colour.
  def test_what_is_painted_after_the_clear_is_what_the_sprite_remembers
    prog = field_program do |hero, step|
      (step == 3).then do
        clear_screen :blue
        fill_rect START[0], START[1], SIDE, SIDE, :green
      end
      (step > 4).then { hero.move :right, by: 16 }
    end

    seen = colors_after(prog, 8)

    assert_equal ONE, seen[:green], "the wall under the sprite is whole once it steps off"
    assert_equal ONE, seen[:red]
    assert_equal field - (2 * ONE), seen[:blue]
  end
end

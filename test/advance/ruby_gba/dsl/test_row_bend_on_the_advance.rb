# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_row_bend.rb whose games show a second background while another is showing, and
# a Game Boy Color's hardware cannot, so they play on the Advance's runs alone.
class TestRowBendOnTheAdvance < Minitest::Test
  include Differential

  BendForm = RubyGBA::IR::Backends::GBA::BendForm

  # A BEND AND A MOVING SPRITE, which is the pairing a game actually writes — a boat on
  # rippling water, a jellyfish drifting over a lake. Both halves agreed on their own long
  # before this test: what it watches is that they agree AT THE SAME MOMENT.
  #
  # They did not. A sprite is placed in the gap between frames, so it shows what the last
  # body did; the rows used to be worked out while the picture was being drawn, so they
  # showed what THIS body had just done — one frame further on. No frame count lined both
  # up, so the strongest test in the project could not be pointed at the combination at all.
  # Working the rows out in the gap, beside the sprites, is what put them in step.
  private def ripple_and_sprite_program(layers: 1)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :bar, "." => :transparent, "#" => :red do
        <<~ART
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
        ART
      end
      image(:boat, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      ripple = table :ripple, (0...64).map { |i| (Math.sin(i * 2 * Math::PI / 64) * 3).round }
      phase = var :phase, 0
      layers.times do |i|
        water = background :"water#{i}", tiles: :stripes, map: Array.new(20) { "#" * 30 }
        water.scroll_each_row { |row| ripple[(row - phase + (i * 7)) % 64] }
      end
      boat = sprite :boat, at: [20, 40]
      game_loop do
        phase.add! 1
        boat.move :right, by: 4
      end
    end
    b.finalize_program
    b.program
  end

  # ...and the same when no engine was free to feed the rows and the display is interrupted
  # for them instead. The two lowerings hand over the same numbers at the same moment, so a
  # game cannot tell which it got — which is the property the whole split rests on.
  #
  # The console is run one frame longer still. That is boot, not behavior: four tables to
  # clear and an interrupt to arm is more than a program gets through before its first pass.
  def test_a_bend_the_interrupt_feeds_agrees_with_a_moving_sprite_too
    program = ripple_and_sprite_program(layers: 4)
    refute BendForm.fed_by_dma?(program), "four bending layers is one more than there are engines"
    (2..5).each do |f|
      assert_backends_agree(program, frames: f, console_frames: f + 2, name: "ISP#{f}")
    end
  end

  # --- more than one layer bending ---

  # Two layers, each with its own bend, going opposite ways. Working one row's offset out
  # needs the accumulator the row number is sitting in, so the second layer would read a
  # clobbered row unless every bend is told the row before any offset is worked out.
  private def two_bends_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:back_bar, "." => :blue, "#" => :red) { (["##......"] * 8).join("\n") }
      image(:front_bar, "." => :transparent, "#" => :white) { (["....##.."] * 8).join("\n") }
      tiles :back_set, "#" => :back_bar
      tiles :front_set, "#" => :front_bar
      back = background :back, tiles: :back_set, map: Array.new(20) { "#" * 30 }
      front = background :front, tiles: :front_set, map: Array.new(20) { "#" * 30 }
      back.scroll_each_row { |row| row % 8 }
      front.scroll_each_row { |row| -(row % 8) }
      game_loop { }
    end
    b.finalize_program
    b.program
  end

  def test_each_layer_bends_by_its_own_amount
    i = game_player.run(two_bends_program)
    red = ->(y) { (0...16).select { |x| i.screen.pixel(x, y) == Color::PRESETS[:red] } }
    white = ->(y) { (0...16).select { |x| i.screen.pixel(x, y) == Color::PRESETS[:white] } }

    assert_equal [0, 1, 8, 9], red.call(0), "row 0 is unbent on both layers"
    assert_equal [4, 5, 12, 13], white.call(0)
    # By row 4 the back layer has slid 4 left and the front 4 right — opposite ways, which
    # a single shared row offset could not produce.
    assert_equal [4, 5, 12, 13], red.call(4)
    assert_equal [8, 9], white.call(4)
  end

  def test_two_bending_layers_agree_across_backends
    assert_backends_agree(two_bends_program, frames: 4, name: "TWOB")
  end

  # THREE layers bending at once, which is as many as there are engines to feed them —
  # each with its own table, its own engine and its own rhythm. Every one of the 38,400
  # pixels, because the way this breaks is subtle: two engines aimed at one scroll register,
  # or a table handed to the wrong layer, still draws a picture that bends.
  private def three_bends_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:back_bar, "." => :blue, "#" => :red) { (["##......"] * 8).join("\n") }
      image(:mid_bar, "." => :transparent, "#" => :green) { (["..##...."] * 8).join("\n") }
      image(:front_bar, "." => :transparent, "#" => :white) { (["....##.."] * 8).join("\n") }
      tiles :back_set, "#" => :back_bar
      tiles :mid_set, "#" => :mid_bar
      tiles :front_set, "#" => :front_bar
      back = background :back, tiles: :back_set, map: Array.new(20) { "#" * 30 }
      mid = background :mid, tiles: :mid_set, map: Array.new(20) { "#" * 30 }
      front = background :front, tiles: :front_set, map: Array.new(20) { "#" * 30 }
      back.scroll_each_row { |row| row % 8 }
      mid.scroll_each_row { |row| (row * 2) % 8 }
      front.scroll_each_row { |row| -(row % 8) }
      game_loop { }
    end
    b.finalize_program
    b.program
  end

  def test_three_bending_layers_are_each_fed_by_an_engine
    assert BendForm.fed_by_dma?(three_bends_program)
    assert_backends_agree(three_bends_program, frames: 4, name: "TRIB")
  end
end

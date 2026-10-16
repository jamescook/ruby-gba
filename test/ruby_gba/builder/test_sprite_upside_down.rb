# frozen_string_literal: true

require "test_helper"
require "differential"

# A POSE MAY BE ANOTHER POSE TURNED TOP TO BOTTOM, storing no pixels of its own — `mirror`'s
# other way. A reflection in water, a stalactite drawn from a stalagmite, an arrow that points
# up or down: the console draws an object upside down for nothing, as it draws one reversed.
#
# As with `mirror`, what can go wrong is the PLACE: art near the top of its canvas must land
# the same distance from the bottom turned over. So the tests compare the two backends on
# frames showing each turned pose, where the interpreter draws the turned picture's own pixels.
class TestSpriteUpsideDown < Minitest::Test
  runs_on :reference

  include Differential

  CANVAS = 32
  INK = RubyGBA::Graphics::Color.rgb(31, 20, 0)
  EDGE = RubyGBA::Graphics::Color.rgb(0, 31, 10)
  CLEAR = RubyGBA::Graphics::Color.rgb(0, 0, 1)

  # A block at (+ox+, +oy+) with its top row and its left column different colours, so a pose
  # turned the wrong way, or drawn in the wrong place, shows up as different pixels.
  private def lopsided(ox, oy, w = 10, h = 12)
    (0...(CANVAS * CANVAS)).map do |i|
      x = i % CANVAS
      y = i / CANVAS
      next CLEAR unless x >= ox && x < ox + w && y >= oy && y < oy + h

      x == ox || y == oy ? EDGE : INK
    end
  end

  # A sprite whose cycle runs through +poses+ and then the turned pictures +turn+ makes of
  # them: +turn+ is handed the builder and the names, and gives back the extra names.
  private def program(poses, &turn)
    canvas = CANVAS
    clear = CLEAR
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names = poses.each_with_index.map do |data, k|
        image :"pose#{k}", width: canvas, height: canvas, data: data, transparent: clear
        :"pose#{k}"
      end
      sprite :hero, at: [40, 30], frames: names + instance_exec(names, &turn), rate: 3
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  def test_an_upside_down_pose_draws_as_the_picture_turned_over
    assert_backends_agree(program([lopsided(6, 4)]) { |names| [upside_down(names[0])] }, frames: 12)
  end

  # Art against the top and against the bottom of its canvas, where a turned pose drawn at the
  # source's own offset would land visibly wrong.
  def test_an_upside_down_pose_of_art_pushed_to_one_edge_lands_in_the_right_place
    assert_backends_agree(program([lopsided(6, 0)]) { |names| [upside_down(names[0])] }, frames: 12)
    assert_backends_agree(program([lopsided(6, CANVAS - 12)]) { |names| [upside_down(names[0])] }, frames: 12)
  end

  # IT COMPOSES WITH `mirror`: a picture turned both ways is one more bit, not a special case.
  # The cycle is four poses three frames each, so four runs three frames apart end on each of
  # them once.
  def test_a_pose_turned_both_ways_draws_the_same_on_both_backends
    turned = program([lopsided(6, 4)]) { |names| [mirror(names[0]), upside_down(names[0]), mirror(upside_down(names[0]))] }

    [12, 15, 18, 21].each { |frames| assert_backends_agree(turned, frames: frames) }
  end

  # A picture bigger than the console draws is cut into pieces, and each piece's place must be
  # reflected within the whole picture, not within its own box.
  def test_a_big_picture_turned_upside_down_draws_the_same_on_both_backends
    wide = 96
    tall = 48
    data = (0...(wide * tall)).map do |i|
      x = i % wide
      y = i / wide
      next CLEAR unless y < 30 && x < 70

      x < 8 || y < 8 ? EDGE : INK
    end
    clear = CLEAR
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :cruiser, width: wide, height: tall, data: data, transparent: clear
      sprite :hero, at: [40, 30], frames: [:cruiser, upside_down(:cruiser)], rate: 3
      game_loop {}
    end
    builder.finalize_program

    [12, 15].each { |frames| assert_backends_agree(builder.program, frames: frames) }
  end

  def test_turning_a_picture_that_is_not_defined_says_so
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { upside_down(:nobody) } }

    assert_match(/upside_down names the picture :nobody/, error.message)
    assert_match(/not defined/, error.message)
  end
end

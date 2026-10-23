# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_sprite_off_screen.rb whose games turn or resize a sprite, and a Game Boy
# Color's hardware cannot, so they play on the Advance's runs alone.
class TestSpriteOffScreenOnTheAdvance < Minitest::Test
  include Differential

  WIDTH = 240
  HEIGHT = 160
  FLOOR = Color.resolve(:gray)

  def self.checks(width, height)
    (0...height).map { |row| (0...width).map { |col| (row + col).even? ? "#" : "o" }.join }.join("\n")
  end

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A game over a plain floor, with +cast+ declaring what stands on it.
  private def cast_on_floor(&cast)
    program do
      screen :tiled
      image(:floor, "#" => :gray) { (["########"] * 8).join("\n") }
      tiles :floor, "#" => :floor
      background :floor, tiles: :floor, map: ["#" * 30] * 20
      instance_exec(&cast)
    end
  end

  # One sprite of +width+ by +height+ at +at+, resized to +scale+ and turned to +angle+ when
  # those are given.
  private def one_sprite(at, width, height = width, scale: nil, angle: nil)
    cast_on_floor do
      image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreenOnTheAdvance.checks(width, height) }
      thing = sprite :block, at: at
      thing.scale scale if scale
      thing.face_angle angle if angle
      game_loop {}
    end
  end

  # The rows and the columns of the screen the interpreter drew something on, as two ranges,
  # or nil for a picture that is all floor.
  private def drawn_on(program, frames: 3)
    screen = game_player.run(program, frames: frames).screen
    rows = (0...HEIGHT).select { |y| (0...WIDTH).any? { |x| screen.pixel(x, y) != FLOOR } }
    cols = (0...WIDTH).select { |x| (0...HEIGHT).any? { |y| screen.pixel(x, y) != FLOOR } }
    rows.empty? ? nil : [rows.min..rows.max, cols.min..cols.max]
  end

  # Both backends show the floor and nothing else.
  private def assert_nothing_drawn(program, name:, frames: 3)
    assert_nil drawn_on(program, frames: frames), "#{name}: the interpreter drew it"
    assert_backends_agree(program, frames: frames, name: name)
  end

  def test_a_turning_sprite_far_off_the_screen_is_not_drawn
    [[[50, 200], 64, 2.0], [[460, 60], 64, 2.0], [[50, -200], 64, 2.0], [[-400, 60], 64, 2.0], [[50, 250], 32, 2.0],
     [[50, -140], 32, 1.5], [[600, 60], 16, 1.0], [[50, 192], 64, 2.0], [[50, -96], 64, 2.0], [[415, 60], 64, 2.0],
     [[416, 60], 64, 2.0], [[417, 60], 64, 2.0], [[-240, 60], 64, 2.0], [[-241, 60], 64, 2.0], [[50, 207], 32, 2.0],
     [[50, 208], 32, 2.0], [[50, -80], 32, 2.0], [[50, -81], 32, 2.0]].each do |at, size, scale|
      assert_nothing_drawn(one_sprite(at, size, scale: scale, angle: 30), name: "SPIN#{at.sum.abs}")
    end
  end

  def test_a_turning_sprite_part_way_off_an_edge_is_the_same_on_the_console
    [[[50, 150], 32, 2.0], [[50, -20], 32, 2.0], [[-20, 60], 64, 2.0], [[230, 60], 64, 2.0], [[50, 130], 64, 1.0]].each do |at, size, scale|
      game = one_sprite(at, size, scale: scale, angle: 30)

      refute_nil drawn_on(game), "at #{at.inspect}"
      assert_backends_agree(game, frames: 3, name: "PART#{at.sum.abs}")
    end
  end

  # THE ONE THAT COMES ROUND. Its box is 128 rows, so with its top between row 129 and row
  # 159 it runs past the last row the console counts, and the end of it shows at the top
  # of the screen; and with its top from 127 to 97 rows above the screen, the start of it
  # is counted as rows 129 to 159 and shows at the bottom.
  def test_a_tall_turning_sprite_hanging_off_the_bottom_shows_its_end_at_the_top
    game = one_sprite([50, 172], 64, scale: 2.0)
    rows, = drawn_on(game)

    assert_equal 0..159, rows, "rows 140 to 159 where it stands, and rows 0 to 11 where it comes round"
    assert_backends_agree(game, frames: 3, name: "ROUNDTOP")
  end

  def test_a_tall_turning_sprite_hanging_off_the_top_shows_its_start_at_the_bottom
    game = one_sprite([50, -90], 64, scale: 2.0)
    rows, = drawn_on(game)

    assert_equal 0..159, rows, "rows 0 to 5 where it stands, and rows 134 to 159 where it comes round"
    assert_backends_agree(game, frames: 3, name: "ROUNDBOT")
  end

  def test_a_tall_turning_sprite_comes_round_at_any_angle_and_any_width
    [[[50, 165], 64, 64, 2.0, 45], [[120, -100], 64, 64, 1.6, 200], [[200, 180], 32, 64, 2.0, 0], [[10, -70], 32, 64, 1.9, 90]].each do |at, width, height, scale, angle|
      assert_backends_agree(one_sprite(at, width, height, scale: scale, angle: angle), frames: 3, name: "ROUND#{at.sum.abs}")
    end
  end

  # The furthest off the screen it stands and is still drawn: one row of its box on the
  # screen, and the rest of the far end where it comes round.
  def test_a_tall_turning_sprite_at_the_last_place_it_shows_is_the_same_on_the_console
    { 191 => 0..30, -95 => 129..159 }.each do |y, rows_round|
      game = one_sprite([50, y], 64, scale: 2.0)
      rows, = drawn_on(game)

      assert_equal (rows_round.to_a + [y.positive? ? 159 : 0]).minmax, rows.minmax, "at row #{y}"
      assert_backends_agree(game, frames: 3, name: "LAST#{y.abs}")
    end
  end

  # Moving through the rows where it comes round, what it drew there on one frame is gone
  # on the next. Rising, the part that comes round gets smaller, so a frame that left the
  # last frame's part behind would show it.
  def test_a_tall_turning_sprite_moving_through_the_rows_where_it_comes_round_leaves_nothing_behind
    { [196, -5] => "RISE", [-100, 5] => "SINK" }.each do |(y, step), name|
      moving = cast_on_floor do
        image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreenOnTheAdvance.checks(64, 64) }
        slab = sprite :block, at: [50, y]
        slab.scale 2.0
        game_loop { slab.move 0, step }
      end

      (3..10).each { |frames| assert_backends_agree(moving, frames: frames, name: "#{name}#{frames}") }
    end
  end

  # A SPRITE THAT ONLY TURNS NEVER COMES ROUND, tall box or not. Its picture stays within
  # half its own diagonal of its middle at every angle, so the rows of the box that come
  # round are rows it never reaches while any of it is on the screen — and with none of it
  # on the screen it is not drawn, though its box still is.
  def test_a_tall_sprite_that_only_turns_never_shows_at_the_other_edge
    [150, 165, 173, 174, 179, 185, 191, 200, -40, -77, -78, -80, -95, -100, -120].each do |y|
      game = one_sprite([88, y], 64, angle: 45)
      rows, = drawn_on(game)

      assert(rows.nil? || (y.positive? ? rows.min >= 100 : rows.max < 60), "at row #{y} it drew on rows #{rows.inspect}")
      assert_backends_agree(game, frames: 3, name: "TURN#{y.abs}#{y.positive? ? 'B' : 'T'}")
    end
  end

  # ...and in blocks, where each row that shows is worked out from where the box is counted
  # as starting.
  def test_a_tall_turning_sprite_that_comes_round_is_the_same_in_blocks
    [[[50, 172], 4], [[50, -90], 4], [[90, 165], 7], [[120, -100], 5]].each do |at, size|
      game = cast_on_floor do
        image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreenOnTheAdvance.checks(64, 64) }
        slab = sprite :block, at: at
        slab.scale 2.0
        pixelate size
        game_loop {}
      end

      assert_backends_agree(game, frames: 3, name: "BLOCKS#{at.sum.abs}#{size}")
    end
  end
end

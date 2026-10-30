# frozen_string_literal: true

require "test_helper"
require "differential"

# The floor every game here stands on, shared with the Advance's cartridge's tests
# (test/lowering/gba/vblank/builder/test_sprite_off_screen_cartridge.rb).
module SpriteOffScreenGames
  include SharedConstants

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A game over a plain floor that covers the whole screen of the console this run plays it on,
  # with +cast+ declaring what stands on it.
  private def cast_on_floor(&cast)
    cols, rows = screen_played.map { |pixels| pixels / 8 }
    program do
      screen :tiled
      image(:floor, "#" => :gray) { (["########"] * 8).join("\n") }
      tiles :floor, "#" => :floor
      background :floor, tiles: :floor, map: ["#" * cols] * rows
      instance_exec(&cast)
    end
  end

  # The width and height of the screen of the console this run plays the game on.
  private def screen_played = VBlank::Console.described(game_console).screen_size
end

# A SPRITE THE GAME PUTS OFF THE SCREEN IS NOT ON IT, however far off that is.
#
# The console keeps a sprite's row as one of 256 and its column as one of 512, and a place
# outside those comes round: a sprite parked at row 300 is drawn at row 44. Nobody means
# that, so the framework keeps such a sprite off the picture, and the two backends are held
# to one picture for every place a game can name.
#
# One case cannot be kept off, and both backends draw it: the box of a sprite 64 pixels
# tall that turns or resizes is 128 rows, which is more than the 96 rows the console counts
# past the bottom of the screen. Hanging far enough off the top or the bottom, the far end
# of that box shows at the other edge.
#
# What the Advance's cartridge costs for it, and what its table of sprites says, are in
# test/lowering/gba/vblank/builder/test_sprite_off_screen_cartridge.rb.
class TestSpriteOffScreen < Minitest::Test
  include Differential
  include SpriteOffScreenGames


  WIDTH = 240
  HEIGHT = 160
  FLOOR = Color.resolve(:gray)

  def self.checks(width, height)
    (0...height).map { |row| (0...width).map { |col| (row + col).even? ? "#" : "o" }.join }.join("\n")
  end


  # One sprite of +width+ by +height+ at +at+, resized to +scale+ and turned to +angle+ when
  # those are given.
  private def one_sprite(at, width, height = width, scale: nil, angle: nil)
    cast_on_floor do
      image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(width, height) }
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
    width, height = size_of(screen)
    rows =(0...height).select { |y| (0...width).any? { |x| screen.pixel(x, y) != FLOOR } }
    cols = (0...width).select { |x| (0...height).any? { |y| screen.pixel(x, y) != FLOOR } }
    rows.empty? ? nil : [rows.min..rows.max, cols.min..cols.max]
  end

  # The columns and rows of the screen a picture was drawn on: the Color's is smaller, and the
  # desktop's picture is the Advance's.
  private def size_of(screen)
    screen.respond_to?(:width) ? [screen.width, screen.height] : [WIDTH, HEIGHT]
  end

  # Both backends show the floor and nothing else.
  private def assert_nothing_drawn(program, name:, frames: 3)
    assert_nil drawn_on(program, frames: frames), "#{name}: the interpreter drew it"
    assert_backends_agree(program, frames: frames, name: name)
  end

  # --- a sprite that stands upright ---

  # The places just past the bottom or the right edge are counted from that edge, so they are
  # off whatever the size of the screen the run plays on. The rest are where the console's count
  # of rows or columns comes round, which no screen's size moves: 191 to 193 are a sprite 64 rows
  # tall whose far end reaches round past row 256, which only a screen shorter than them has below
  # it.
  def test_a_sprite_far_below_the_screen_is_not_drawn
    bottom = screen_played.last
    round_the_count = [[191, 64], [192, 64], [193, 64]].select { |row, _| row >= bottom }
    ([[300, 16], [250, 16], [bottom + 40, 64], [bottom + 70, 64], [bottom, 16], [4000, 32]] + round_the_count)
      .each do |row, size|
      assert_nothing_drawn(one_sprite([100, row], size), name: "BELOW#{row}")
    end
  end

  def test_a_sprite_far_above_the_screen_is_not_drawn
    [[[100, -16], 16], [[100, -96], 16], [[100, -97], 16], [[100, -100], 64], [[100, -300], 16], [[100, -4000], 32]].each do |at, size|
      assert_nothing_drawn(one_sprite(at, size), name: "ABOVE#{at[1].abs}")
    end
  end

  def test_a_sprite_far_to_either_side_of_the_screen_is_not_drawn
    [[500, 16], [600, 16], [480, 64], [screen_played.first, 16], [-300, 16], [-16, 16], [-500, 64], [9000, 32],
     [447, 64], [448, 64], [449, 64], [-272, 64], [-273, 64]].each do |x, size|
      assert_nothing_drawn(one_sprite([x, 60], size), name: "SIDE#{x.abs}")
    end
  end

  # What keeps a far sprite off must not take a near one with it: a sprite with one row or
  # one column still on the screen shows that much.
  def test_a_sprite_part_way_off_any_edge_still_shows_the_part_that_is_on
    right, bottom = size_of(game_player.run(one_sprite([0, 0], 16), frames: 1).screen).map { |n| n - 1 }
    { [-15, 60] => [60..75, 0..0], [right, 60] => [60..75, right..right], [100, -15] => [0..0, 100..115],
      [100, bottom] => [bottom..bottom, 100..115], [-63, -63] => [0..0, 0..0] }.each do |at, where|
      size = at.include?(-63) ? 64 : 16
      game = one_sprite(at, size)

      assert_equal where, drawn_on(game), "at #{at.inspect}"
      assert_backends_agree(game, frames: 3, name: "EDGE#{at.sum.abs}")
    end
  end

  # A sprite that walks off an edge and keeps going never comes back from the other side.
  def test_a_sprite_that_keeps_walking_off_the_screen_does_not_come_back
    { [40, 0] => 15, [-40, 0] => 15, [0, 40] => 12, [0, -40] => 12 }.each do |(dx, dy), frames|
      walking = cast_on_floor do
        image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(16, 16) }
        walker = sprite :block, at: [112, 72]
        game_loop { walker.move dx, dy }
      end

      # Far enough to have gone right round the console's count of columns or rows.
      (6..frames).step(3) { |played| assert_nothing_drawn(walking, frames: played, name: "WALK#{dx.abs}#{dy.abs}#{played}") }
    end
  end

  # A pose stored trimmed to what it draws stands further along than its canvas, by an
  # amount that changes with the pose.
  def test_poses_of_different_sizes_are_kept_off_too
    art = lambda do |left, top, right, bottom|
      (0...32).map { |row| (0...32).map { |col| (left..right).cover?(col) && (top..bottom).cover?(row) ? "#" : "." }.join }.join("\n")
    end
    [[100, 290], [100, -330], [520, 60], [-290, 60]].each do |at|
      posed = cast_on_floor do
        image(:small, "#" => :red, "." => :transparent) { art.call(16, 16, 27, 29) }
        image(:low, "#" => :red, "." => :transparent) { art.call(2, 1, 30, 12) }
        sprite :posed, at: at, frames: %i[small low], rate: 2
        game_loop {}
      end

      assert_nothing_drawn(posed, frames: 3, name: "POSE#{at.sum.abs}A") # showing the first pose
      assert_nothing_drawn(posed, frames: 5, name: "POSE#{at.sum.abs}B") # ...and the second
    end
  end

  # A pose drawn the other way round is read with two bits more, which must not count as
  # distance: near, it is drawn where it stands, and far, it is kept off like any other.
  def test_a_pose_drawn_the_other_way_round_is_drawn_near_and_kept_off_far
    turned_round = lambda do |at|
      cast_on_floor do
        image(:arrow, "#" => :red, "." => :transparent) { (0...16).map { |row| ("#" * (row + 1)).ljust(16, ".") }.join("\n") }
        pointer = sprite :pointer, at: at, facing: { right: :arrow, left: mirror(:arrow), up: upside_down(:arrow) }
        game_loop { pointer.face :up }
      end
    end

    assert_equal [40..55, 30..45], drawn_on(turned_round.call([30, 40])), "near, upside down"
    assert_backends_agree(turned_round.call([30, 40]), frames: 3, name: "UPSIDENEAR")
    [[30, 300], [30, -200], [600, 40]].each { |at| assert_nothing_drawn(turned_round.call(at), name: "UPSIDE#{at.sum.abs}") }
  end

  # A line of text stands where the program wrote it, so nothing about where it stands is
  # worked out as the game runs and no test is spent on it.
  def test_text_written_far_off_is_not_drawn
    lettered = lambda do |y|
      cast_on_floor do
        draw_text "SCORE", 8, y, :white
        game_loop {}
      end
    end
    assert_nothing_drawn(lettered.call(300), name: "TEXTFAR")
  end

  def test_the_things_of_a_pool_are_kept_off_one_by_one
    pooled = cast_on_floor do
      image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(16, 16) }
      things = pool :thing, x: 0, y: 0, capacity: 6, image: :block
      things.spawn x: 100, y: 300
      things.spawn x: 500, y: 60
      things.spawn x: 30, y: 40
      things.spawn x: -300, y: 250
      game_loop {}
    end

    assert_equal [40..55, 30..45], drawn_on(pooled), "the one thing that is on the screen"
    assert_backends_agree(pooled, frames: 3, name: "POOL")
  end
end

# frozen_string_literal: true

require "test_helper"
require "differential"

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
class TestSpriteOffScreen < Minitest::Test
  runs_on :reference
  include Differential

  WIDTH = 240
  HEIGHT = 160
  FLOOR = Color.resolve(:gray)

  def self.checks(width, height)
    (0...height).map { |row| (0...width).map { |col| (row + col).even? ? "#" : "o" }.join }.join("\n")
  end

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A game over a plain floor, with +cast+ declaring what stands on it.
  def cast_on_floor(&cast)
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
  def one_sprite(at, width, height = width, scale: nil, angle: nil)
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
  def drawn_on(program, frames: 3)
    screen = Reference.new.run(program, frames: frames).screen
    rows = (0...HEIGHT).select { |y| (0...WIDTH).any? { |x| screen.pixel(x, y) != FLOOR } }
    cols = (0...WIDTH).select { |x| (0...HEIGHT).any? { |y| screen.pixel(x, y) != FLOOR } }
    rows.empty? ? nil : [rows.min..rows.max, cols.min..cols.max]
  end

  # Both backends show the floor and nothing else.
  def assert_nothing_drawn(program, name:, frames: 3)
    assert_nil drawn_on(program, frames: frames), "#{name}: the interpreter drew it"
    assert_backends_agree(program, frames: frames, name: name)
  end

  # --- a sprite that stands upright ---

  def test_a_sprite_far_below_the_screen_is_not_drawn
    [[[100, 300], 16], [[100, 250], 16], [[100, 200], 64], [[100, 230], 64], [[100, 160], 16], [[100, 4000], 32],
     [[100, 191], 64], [[100, 192], 64], [[100, 193], 64]].each do |at, size|
      assert_nothing_drawn(one_sprite(at, size), name: "BELOW#{at[1]}")
    end
  end

  def test_a_sprite_far_above_the_screen_is_not_drawn
    [[[100, -16], 16], [[100, -96], 16], [[100, -97], 16], [[100, -100], 64], [[100, -300], 16], [[100, -4000], 32]].each do |at, size|
      assert_nothing_drawn(one_sprite(at, size), name: "ABOVE#{at[1].abs}")
    end
  end

  def test_a_sprite_far_to_either_side_of_the_screen_is_not_drawn
    [[[500, 60], 16], [[600, 60], 16], [[480, 60], 64], [[240, 60], 16], [[-300, 60], 16], [[-16, 60], 16],
     [[-500, 60], 64], [[9000, 60], 32], [[447, 60], 64], [[448, 60], 64], [[449, 60], 64], [[-272, 60], 64],
     [[-273, 60], 64]].each do |at, size|
      assert_nothing_drawn(one_sprite(at, size), name: "SIDE#{at[0].abs}")
    end
  end

  # What keeps a far sprite off must not take a near one with it: a sprite with one row or
  # one column still on the screen shows that much.
  def test_a_sprite_part_way_off_any_edge_still_shows_the_part_that_is_on
    { [-15, 60] => [60..75, 0..0], [239, 60] => [60..75, 239..239], [100, -15] => [0..0, 100..115],
      [100, 159] => [159..159, 100..115], [-63, -63] => [0..0, 0..0] }.each do |at, where|
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

  # A picture too big for one of the console's sprites is drawn as several, and each is a
  # box of its own: the bottom one of a tall picture can be off the screen, and past the
  # console's last row, while the top of the picture is on it.
  def test_a_piece_of_a_big_picture_that_is_off_the_screen_does_not_come_round
    tall = cast_on_floor do
      image(:pole, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(16, 256) }
      sprite :pole, at: [100, 10]
      game_loop {}
    end

    assert_equal [10..159, 100..115], drawn_on(tall)
    assert_backends_agree(tall, frames: 3, name: "POLE")
  end

  def test_a_big_picture_far_off_the_screen_is_not_drawn_piece_by_piece
    beam = lambda do |at|
      cast_on_floor do
        image(:beam, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(256, 16) }
        sprite :beam, at: at
        game_loop {}
      end
    end

    [[-300, 60], [300, 60], [-700, 60], [10, 400]].each { |at| assert_nothing_drawn(beam.call(at), name: "BEAM#{at.sum.abs}") }
    assert_equal [60..75, 0..55], drawn_on(beam.call([-200, 60])), "part way off the left it shows what is on"
    assert_backends_agree(beam.call([-200, 60]), frames: 3, name: "BEAMON")
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
  def test_text_written_on_the_screen_costs_no_test_and_text_written_far_off_is_not_drawn
    lettered = lambda do |y|
      cast_on_floor do
        draw_text "SCORE", 8, y, :white
        game_loop {}
      end
    end
    near = RubyGBA::IR::Backends::GBA.new.lower(lettered.call(8)).bytesize
    far = RubyGBA::IR::Backends::GBA.new.lower(lettered.call(300)).bytesize

    assert_operator near, :<, far, "the letters far off are tested, the ones on the screen are not"
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

  # --- a sprite that turns or resizes ---

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
        image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(64, 64) }
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
        image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(64, 64) }
        slab = sprite :block, at: at
        slab.scale 2.0
        pixelate size
        game_loop {}
      end

      assert_backends_agree(game, frames: 3, name: "BLOCKS#{at.sum.abs}#{size}")
    end
  end

  # --- what a test reading the console's table is told ---

  # A sprite that is off the screen is still in the table, which is what tells it from one
  # the game switched off. Where the table can say its place, it says the game's own.
  def test_a_sprite_off_the_screen_is_still_a_row_of_the_consoles_table
    require_emulator!
    rom = RubyGBA.build("PARKED", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(16, 16) }
      image(:slab, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(64, 64) }
      sprite :near, at: [250, 170], facing: { right: :block }
      sprite :far, at: [100, 300], facing: { right: :block }
      sprite :hidden, at: [100, 300], facing: { right: :block }, shown: false
      spun = sprite :spun, at: [100, 300], facing: { right: :slab }
      spun.scale 2.0
      game_loop {}
    end
    reader = assert_emulator_loads_rom(rom, frames: 4)
    near, far, spun = %i[near far spun].map { |name| reader.sprites(name) }

    assert_equal [[250, 170]], near.map { |row| [row.x, row.y] }, "just off the edge, it is where the game put it"
    assert_equal [[100, HEIGHT]], far.map { |row| [row.x, row.y] }, "too far down for the table to say, it reads as the first row below"
    assert_equal [HEIGHT], spun.map(&:y), "and so does a box too tall to stand there turned"
    assert_empty reader.sprites(:hidden), "where one the game hid is not in the table at all"
  end
end

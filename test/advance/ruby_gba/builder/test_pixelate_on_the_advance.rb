# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TESTS OF ruby_gba/builder/test_pixelate.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# Drawing the picture in flat blocks, as the display draws it.
#
# The rule is the emulator's, read out of its renderer and then measured on it: the blocks
# are fixed to the SCREEN, and each takes the colour the picture has at the block's top
# left corner. So the thing to assert is that rule against the picture as drawn, and then
# that the console shows the same picture pixel for pixel, which is what keeps the rule
# honest — every place it bends is a place the two would disagree.
class TestPixelateOnTheAdvance < Minitest::Test
  include Differential

  WIDTH = 240
  HEIGHT = 160

  # Two tiles with nothing flat about them, so a block's colour depends on where it starts.
  STRIPES = (0...8).map { |row| (0...8).map { |col| (col * 3) + row < 9 ? "#" : "." }.join }.join("\n")
  STEPS = (0...8).map { |row| (0...8).map { |col| col > row ? "#" : "." }.join }.join("\n")
  ROOM = (0...32).map { |row| (0...32).map { |col| (((row * 2) + col) % 3).zero? ? "a" : "b" }.join }

  # The two tiles and the set that names them, said inside a game being built.
  ROOM_TILES = proc do
    image(:stripes, "#" => :red, "." => :blue) { STRIPES }
    image(:steps, "#" => :green, "." => :white) { STEPS }
    tiles :set, "a" => :stripes, "b" => :steps
  end

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A room of those tiles, scrolled off the tile grid, with +said+ run before the loop.
  private def tiled_room(&said)
    program do
      screen :tiled
      instance_exec(&ROOM_TILES)
      room = background :room, tiles: :set, map: ROOM
      room.scroll_to 5, 3
      instance_exec(room, &said) if said
      game_loop {}
    end
  end

  private def picture_of(program, frames: 2)
    screen = game_player.run(program, frames: frames).screen
    Array.new(HEIGHT) { |y| Array.new(WIDTH) { |x| screen.pixel(x, y) } }
  end

  # Every pixel of +blocks+ is the pixel +drawn+ has at the top left corner of its block.
  private def assert_blocks_of(drawn, blocks, wide, tall)
    wrong = (0...HEIGHT).to_a.product((0...WIDTH).to_a).reject do |y, x|
      blocks[y][x] == drawn[y - (y % tall)][x - (x % wide)]
    end

    assert_empty wrong.first(5), "#{wrong.size} pixels are not the colour at the corner of their #{wide}x#{tall} block"
    refute_equal drawn, blocks, "the picture changed at all"
  end

  # --- a background of tiles ---

  # --- a background that turns and resizes ---

  # A board of the two tiles, turned and resized so that nothing in it sits on a grid.
  private def turned_board(size, screen_kind: :rotozoom)
    program do
      screen screen_kind
      instance_exec(&ROOM_TILES)
      board = background :board, tiles: :set, map: ROOM
      board.rotate 20
      board.scale 0.8
      pixelate size if size
      game_loop {}
    end
  end

  # --- sprites ---

  # A 16x16 picture with a different colour at every corner and holes along two edges.
  PATCH = (0...16).map do |row|
    (0...16).map do |col|
      next "." if (col.zero? && row.even?) || (col == 15 && row < 4)

      "ABCD"[(col + (2 * row)) % 4]
    end.join
  end.join("\n")
  PATCH_COLORS = { "." => :transparent, "A" => :red, "B" => :green, "C" => :blue, "D" => :white }.freeze

  # Sprites over a plain floor, off every grid, with +said+ run before the loop.
  private def sprites_at(*places, &said)
    cast_on_floor do
      places.each_with_index { |at, i| sprite :"patch#{i}", at: at, facing: { right: :patch } }
      instance_exec(&said) if said
      game_loop {}
    end
  end

  # A sprite is put into blocks by itself, and the rule has two edges to it. A block that
  # starts off the sprite's left or top shows the sprite's own first column or row. And the
  # sprite's last block runs on to the end of that block, past the sprite's own right edge
  # — but never past its bottom one.
  def test_a_sprite_is_in_blocks_held_inside_itself
    drawn = picture_of(sprites_at([37, 21]))
    blocks = picture_of(sprites_at([37, 21]) { pixelate 4 })
    floor = drawn[100][100]

    assert_equal drawn[21][40], blocks[21][41], "the block began above the sprite, so it shows its first row"
    assert_equal drawn[24][37], blocks[25][38], "and one that began to its left shows its first column"
    assert_equal drawn[24][40], blocks[27][43], "inside, a block is its top left corner"
    assert_equal drawn[28][52], blocks[28][55], "the last block runs past the sprite's right edge"
    refute_equal floor, blocks[28][55]
    assert_equal floor, blocks[37][40], "but nothing is drawn below its bottom edge"
    assert_backends_agree(sprites_at([37, 21]) { pixelate 4 }, frames: 2, name: "SPRITE4")
  end

  # A game over the plain floor, with +cast+ declaring what stands on it.
  private def cast_on_floor(&cast)
    program do
      screen :tiled
      image(:floor, "#" => :gray) { (["########"] * 8).join("\n") }
      tiles :floor, "#" => :floor
      background :floor, tiles: :floor, map: ["#" * 30] * 20
      image(:patch, PATCH_COLORS) { PATCH }
      instance_exec(&cast)
    end
  end

  # A picture of +width+ by +height+ that draws only inside the box given, in the patch's
  # colours, so a pose stored trimmed to what it draws has edges that are not its canvas's.
  def self.art_inside(width, height, left, top, right, bottom)
    (0...height).map do |row|
      (0...width).map do |col|
        next "." unless (left..right).cover?(col) && (top..bottom).cover?(row)

        "ABCD"[(col + (3 * row)) % 4]
      end.join
    end.join("\n")
  end

  SMALL_IN_BIG = art_inside(32, 32, 16, 16, 27, 29)
  LOW_IN_BIG = art_inside(32, 32, 2, 1, 30, 12)
  WIDE = art_inside(96, 48, 5, 3, 90, 44)

  # --- a place in the stack ---

  # A room, two sprites on it and a score over them, each in a layer of its own.
  private def stacked(&said)
    program do
      screen :tiled
      layers :world, :actors, :ui
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :white) { STEPS }
      image(:patch, PATCH_COLORS) { PATCH }
      tiles :set, "a" => :stripes, "b" => :steps
      layer(:world) { background(:room, tiles: :set, map: ROOM).scroll_to 5, 3 }
      layer :actors do
        sprite :hero, at: [37, 21], facing: { right: :patch }
        sprite :guard, at: [150, 90], facing: { right: :patch }
      end
      layer(:ui) { draw_text "SCORE 407", 13, 9, :yellow }
      instance_exec(&said) if said
      game_loop {}
    end
  end

  # `under:` names a layer, and that layer and everything in front of it are left as drawn.
  def test_a_layer_and_everything_in_front_of_it_can_be_left_as_drawn
    drawn = picture_of(stacked, frames: 3)
    everything = picture_of(stacked { pixelate 6 }, frames: 3)
    game_only = picture_of(stacked { pixelate 6, under: :ui }, frames: 3)
    room_only = picture_of(stacked { pixelate 6, under: :actors }, frames: 3)
    yellow = Color.resolve(:yellow)
    lettering = ->(picture) { picture.flatten.each_index.select.with_index { |_at, i| picture[i / WIDTH][i % WIDTH] == yellow } }
    solid = PATCH.lines(chomp: true)
    hero = (0...16).to_a.product((0...16).to_a).reject { |row, col| solid[row][col] == "." }
                   .map { |row, col| [21 + row, 37 + col] }

    refute_equal lettering.call(drawn), lettering.call(everything), "with no place said, the score is in blocks too"
    assert_equal lettering.call(drawn), lettering.call(game_only), "the score is as drawn"
    assert_equal everything[100], game_only[100], "and the game behind it is in blocks"
    assert_equal(hero.map { |y, x| drawn[y][x] }, hero.map { |y, x| room_only[y][x] }, "a sprite in front of the line is as drawn")
    assert_equal everything[130], room_only[130], "and the room behind it is in blocks"
    assert_backends_agree(stacked { pixelate 6, under: :ui }, frames: 3, name: "UNDERUI")
    assert_backends_agree(stacked { pixelate 6, under: :actors }, frames: 3, name: "UNDERACT")
  end

  # --- beside the other things a display does to a picture ---

  # --- a screen the game paints ---

  # Rectangles and single pixels off every grid, on the screen that holds a whole colour
  # in each pixel. +said+ is run after they are painted.
  private def painted_screen(&said)
    program do
      screen :bitmap
      clear_screen :black
      9.times { |i| fill_rect 3 + (i * 25), 5 + (i * 13), 14, 9, %i[red green blue][i % 3] }
      12.times { |i| pixel 7 + (i * 19), 150 - (i * 11), :white }
      instance_exec(&said) if said
      halt
    end
  end

  def test_a_painted_screen_is_shown_in_blocks_and_nothing_painted_changes
    drawn = picture_of(painted_screen)

    assert_blocks_of(drawn, picture_of(painted_screen { pixelate 5 }), 5, 5)
    assert_equal drawn, picture_of(painted_screen { pixelate 5; pixelate 1 }), "the picture is all still there"
    [2, 5, 16].each { |size| assert_backends_agree(painted_screen { pixelate size }, name: "PAINT#{size}") }
  end

end

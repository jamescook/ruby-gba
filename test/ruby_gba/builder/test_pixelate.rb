# frozen_string_literal: true

require "test_helper"
require "differential"

# Drawing the picture in flat blocks, as the display draws it.
#
# The rule is the emulator's, read out of its renderer and then measured on it: the blocks
# are fixed to the SCREEN, and each takes the colour the picture has at the block's top
# left corner. So the thing to assert is that rule against the picture as drawn, and then
# that the console shows the same picture pixel for pixel, which is what keeps the rule
# honest — every place it bends is a place the two would disagree.
class TestPixelate < Minitest::Test
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

  # --- a background of tiles ---

  def test_a_size_written_outside_the_sizes_there_are_is_refused
    error = assert_raises(ArgumentError) { tiled_room { pixelate 17 } }

    assert_match(/from 1 to 16/, error.message)
    assert_match(/17/, error.message)
    assert_match(/1 is the picture as drawn/, assert_raises(ArgumentError) { tiled_room { pixelate 0 } }.message)
  end

  # A number that holds a fraction keeps it in its low bits, so as a size it would be huge.
  def test_a_size_that_holds_a_fraction_is_refused
    error = assert_raises(ArgumentError) do
      tiled_room do
        grown = var :grown, 2.5
        pixelate grown
      end
    end

    assert_match(/whole number of pixels/, error.message)
    assert_match(/to_i/, error.message)
    assert_raises(ArgumentError) { tiled_room { pixelate 2.5 } }
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

  # A picture the game paints while it runs is kept whole, whatever it holds, so its
  # blocks are held inside the whole of it.
  def test_a_sprite_the_game_paints_is_in_blocks_of_the_whole_picture
    painted = cast_on_floor do
      colors :ink, %i[transparent white red blue]
      sheet = list :sheet, capacity: 64, width: :byte
      repeat(64) { sheet.push 0 }
      tag = image :tag, from: sheet, width: 16, height: 8, colors: :ink
      sprite :tag, at: [41, 27]
      repeat(32) { |i| sheet[i + 32] = 0x21 }
      tag.changed
      pixelate 3
      game_loop {}
    end

    assert_backends_agree(painted, frames: 3, name: "PAINTED")
  end

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

  # Which things are in blocks is settled as the cartridge is built, so a game says one place.
  def test_a_game_that_names_two_places_is_refused
    error = assert_raises(ArgumentError) do
      stacked do
        pixelate 6, under: :ui
        pixelate 3
      end
    end

    assert_match(/one place/, error.message)
    assert_match(/:ui/, error.message)
  end

  # --- beside the other things a display does to a picture ---

  # A layer holds things, and blocks are something done to the picture from a place in it.
  def test_pixelate_inside_a_layer_block_is_refused_and_says_what_to_write
    error = assert_raises(ArgumentError) { stacked { layer(:ui) { pixelate 4 } } }

    assert_match(/changes the whole screen/, error.message)
    assert_match(/under: :ui/, error.message)
  end

  def test_a_place_in_the_stack_needs_a_screen_that_has_one
    error = assert_raises(ArgumentError) { painted_screen { pixelate 4, under: :ui } }

    assert_match(/screen :tiled/, error.message)
  end

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
end

# frozen_string_literal: true

require "test_helper"
require "differential"

# One column of a picture, stretched to a height the game works out — what a first-person view
# is made of, and what a scaled sprite is.
#
# The stepping rule is the thing worth pinning: walk DOWN THE SCREEN and ask which picture row
# belongs at each screen row. Walking the picture instead and working out where each of its rows
# lands leaves gaps when stretching and writes some rows twice when squashing. Every test here
# is about pixels, on both backends, because the two agreeing is what makes the interpreter
# usable for debugging the renderer.
class TestDrawColumnAt < Minitest::Test
  include EmulatorSupport

  # Four rows, each its own color, so a stretch is readable row by row.
  BARS = %i[red red green green blue blue white white].freeze
  NAMES = { VBlank::Graphics::Color.resolve(:red) => :red, VBlank::Graphics::Color.resolve(:green) => :green,
            VBlank::Graphics::Color.resolve(:blue) => :blue, VBlank::Graphics::Color.resolve(:white) => :white,
            0 => nil }.freeze

  private def program(&block)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
    end
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def column_on_screen(run, x, from, to)
    (from...to).map { |y| NAMES.fetch(run.screen.pixel(x, y), :other) }
  end

  def test_a_picture_that_does_not_exist_says_how_to_make_one
    err = assert_raises(ArgumentError) do
      program { game_loop { draw_column_at :nope, slice: 0, x: 0, top: 0, height: 4 } }
    end

    assert_match(/image :nope/, err.message)
  end

  def test_a_width_that_is_not_a_whole_number_of_pixels_says_so
    err = assert_raises(ArgumentError) do
      program { game_loop { draw_column_at :bars, slice: 0, x: 0, top: 0, height: 4, width: 0 } }
    end

    assert_match(/width/, err.message)
  end

  # A see-through picture keeps its shape: the pixels it leaves out are left alone rather
  # than painted, which is what a scaled sprite in a first-person view needs — a guard down
  # a corridor, not a guard in a black box.
  def test_a_column_of_a_see_through_picture_leaves_the_background_alone
    prog = program do
      image(:ghost, "." => :transparent, "W" => :white) { "W\n.\n.\nW\n" }
      clear_screen :gray
      game_loop { draw_column_at :ghost, slice: 0, x: 10, top: 0, height: 8 }
    end

    run = game_player.run(prog, frames: 2)

    assert_equal %i[white white other other other other white white],
                 column_on_screen(run, 10, 0, 8).map { |c| c == :other ? :other : c }
    assert_equal VBlank::Graphics::Color.resolve(:gray), run.screen.pixel(10, 3),
                 "the see-through rows must show what was already there"
  end
end

# A PICTURE THAT IS MOSTLY NOTHING, at every size it can be drawn.
#
# The console skips the see-through stretches of a column rather than asking each of its rows
# whether there is a pixel in it, which is what makes a scaled sprite affordable. The
# interpreter does no such thing — it walks every row — so the two agreeing IS the proof that
# the skipping never loses a pixel.
#
# The sizes matter more than the picture does. Turning "rows 12 to 15 of the picture" into
# "these screen rows" divides, and a division that rounds the wrong way at one height would
# shave a row off an edge at that height and no other. So the same picture is drawn at every
# height from squashed to many times the screen, and at tops above and below it.
class TestDrawColumnAtSeeThrough < Minitest::Test
  include EmulatorSupport
  include Differential

  # A ceiling light is the shape that matters: something at the top of the column, something at
  # the bottom, and nothing in the long middle — so a player standing under one is looking at
  # the gap. Two of these columns hold a stretch of one row, which is where an off-by-one shows.
  LAMP = <<~ART
    #.#.
    #...
    ....
    ....
    ....
    ....
    ...#
    ##.#
  ART

  # THE SAME LAMP ON A PICTURE THAT IS NOT A NEAT HEIGHT — thirteen rows rather than eight.
  # Turning a picture row into a screen row divides by the picture's height, and a height that
  # is a power of two divides by shifting where any other multiplies by a number the build
  # works out. The two arrive at the answer differently, so both are drawn here.
  ODD_LAMP = <<~ART
    #.#.
    #...
    ....
    ....
    ....
    ....
    ....
    ....
    ....
    ....
    ....
    ...#
    ##.#
  ART

  HEIGHTS = [1, 2, 3, 5, 8, 13, 16, 31, 64, 159, 160, 161, 400, 1200].freeze

  private def lamp_program(tear_free:, art: LAMP)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: tear_free
      image(:lamp, "." => :transparent, "#" => :white) { art }
      tall = var :tall, 0
      # The direct screen is one page, cleared once: every pass then paints the same pixels
      # over the same picture, so the console read part way through a pass still shows all
      # of it. Cleared at the top of each pass instead, a pass that only just fits in a frame
      # is read just after the clear. The tear-free screen has two pages and shows only a
      # finished one, so it clears each pass.
      clear_screen :gray unless tear_free
      game_loop do
        clear_screen :gray if tear_free
        HEIGHTS.each_with_index do |height, n|
          tall.set! height
          4.times do |slice|
            # Above the screen, on it, and running off the bottom.
            draw_column_at :lamp, slice: slice, x: (n * 4) + slice, top: 0, height: tall
            draw_column_at :lamp, slice: slice, x: (n * 4) + slice + 60, top: -30, height: tall
            draw_column_at :lamp, slice: slice, x: (n * 4) + slice + 120, top: 130, height: tall
          end
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_the_console_skips_the_see_through_parts_and_draws_what_the_interpreter_draws
    assert_backends_agree(lamp_program(tear_free: false), frames: 3, name: "LAMP")
  end

  def test_the_tear_free_screen_skips_them_too
    assert_backends_agree(lamp_program(tear_free: true), frames: 3, name: "TFLAMP")
  end

  def test_a_picture_of_an_awkward_height_skips_them_too
    assert_backends_agree(lamp_program(tear_free: false, art: ODD_LAMP), frames: 3, name: "ODDLAMP")
  end

  def test_a_picture_of_an_awkward_height_skips_them_on_the_tear_free_screen
    assert_backends_agree(lamp_program(tear_free: true, art: ODD_LAMP), frames: 3, name: "TFODD")
  end

  # THE TALLEST PICTURE THAT STILL SKIPS ITS EMPTY ROWS, which is 256 — the commonest height
  # a sprite sheet comes in, and the one where the bookkeeping runs out of room.
  #
  # A column's stretches are shipped as pairs of row numbers and the list ends with 255. At
  # any other height no row can BE 255, so the ending byte is unmistakable; at exactly 256
  # the bottom row is 255, and a stretch that STARTS there reads as the end of the list. The
  # pixel is in the cartridge and never drawn.
  #
  # Two columns, because only one of them is the bug: a lone pixel ON the bottom row is lost,
  # while a stretch that merely ENDS there is read as a last row and is fine.
  TALL_ROWS = 256
  LONE_PIXEL_ROW = TALL_ROWS - 1

  private def tall_picture_program
    data = Array.new(2 * TALL_ROWS, :transparent)
    data[(10 * 2) + 0] = :white                 # column 0, near the top
    data[(LONE_PIXEL_ROW * 2) + 0] = :white     # ...and a lone pixel on the bottom row
    (250...TALL_ROWS).each { |row| data[(row * 2) + 1] = :white } # column 1 ENDS on it
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image :tall, width: 2, height: TALL_ROWS, data: data, transparent: true
      tall = var :tall, 0
      game_loop do
        clear_screen :gray
        tall.set! TALL_ROWS
        # Drawn 1:1 with the bottom of the picture pulled onto the screen, so the last rows
        # are the ones being looked at.
        2.times { |slice| draw_column_at :tall, slice: slice, x: 20 + slice, top: -200, height: tall }
      end
    end
    b.finalize_program
    b.program
  end

  # Where the picture's bottom row lands: 1:1, with the first 200 rows above the screen.
  BOTTOM_ON_SCREEN = LONE_PIXEL_ROW - 200

  def test_the_bottom_row_of_a_256_row_picture_is_drawn
    run = game_player.run(tall_picture_program, frames: 2)

    assert_equal Color.resolve(:white), run.screen.pixel(20, BOTTOM_ON_SCREEN),
                 "the lone pixel on the bottom row"
    assert_equal Color.resolve(:white), run.screen.pixel(21, BOTTOM_ON_SCREEN),
                 "and the stretch that ends on it"
  end

  def test_the_console_draws_the_bottom_row_of_a_256_row_picture_too
    assert_backends_agree(tall_picture_program, frames: 3, name: "TALL256")
  end
end

# The same stretched column on the TEAR-FREE screen, which is the one a first-person view
# actually wants: it repaints the whole screen every frame, and that is what tears.
#
# This screen holds a NUMBER per pixel rather than a color, and refuses a lone byte — the
# smallest write covers a side-by-side pair. So every pixel is a read of its pair, a splice
# of its own half and a write back, and WHICH HALF depends on the column being even or odd.
# That is why the odd column has tests of its own here.
class TestDrawColumnAtTearFree < Minitest::Test
  include EmulatorSupport
  include Differential

  BARS = %i[red red green green blue blue white white].freeze

  # The same program on either screen, so the two can be held against each other.
  private def column_program(tear_free:)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: tear_free
      image :bars, width: 2, height: 4, data: BARS
      image(:ghost, "." => :transparent, "W" => :white) { "W\n.\n.\nW\n" }
      at = var :at, 0
      game_loop do
        # Repainted every pass, because this screen has TWO pages and the loop draws on
        # whichever one is hidden — a clear above the loop would paint only one of them.
        clear_screen :gray
        draw_column_at :bars, slice: 0, x: 10, top: 0, height: 8  # an even column...
        draw_column_at :bars, slice: 0, x: 11, top: 0, height: 8  # ...and an odd one
        at.set! 31 # a column whose evenness cannot be proved while building
        draw_column_at :bars, slice: 1, x: at, top: 10, height: 12
        repeat(4) { |c| draw_column_at :bars, slice: 0, x: (c * 2) + 60, top: 0, height: 6 }
        draw_column_at :ghost, slice: 0, x: 100, top: 0, height: 8
        draw_column_at :ghost, slice: 0, x: 101, top: 0, height: 8
        draw_column_at :bars, slice: 0, x: 120, top: -6, height: 20  # clipped above
        draw_column_at :bars, slice: 0, x: 121, top: 150, height: 40 # clipped below
        draw_column_at :bars, slice: 0, x: 239, top: 0, height: 8    # the last column
        draw_column_at :bars, slice: 0, x: 240, top: 0, height: 8    # off the right edge
        draw_column_at :bars, slice: 0, x: -1, top: 0, height: 8     # off the left edge

        # ...and the same as STRIPS, which write whole pairs where they can. Both parities,
        # a width that covers a pair exactly and one that does not, and both edges.
        draw_column_at :bars, slice: 0, x: 140, top: 20, height: 12, width: 3
        draw_column_at :bars, slice: 0, x: 151, top: 20, height: 12, width: 3
        draw_column_at :bars, slice: 0, x: 160, top: 20, height: 12, width: 2
        draw_column_at :bars, slice: 0, x: 171, top: 20, height: 12, width: 4
        draw_column_at :ghost, slice: 0, x: 180, top: 20, height: 12, width: 3
        draw_column_at :bars, slice: 0, x: 237, top: 20, height: 12, width: 5
        draw_column_at :bars, slice: 0, x: -2, top: 20, height: 12, width: 5
        at.set! 200
        draw_column_at :bars, slice: 0, x: at, top: 100, height: 12, width: 3
      end
    end
    b.finalize_program
    b.program
  end

  # THE POINT OF THE WHOLE BEAD: a game that moves to the tear-free screen to stop the
  # flicker must get the same picture it had before. Every one of the cases above is
  # compared across the two screens, so an odd column spliced into the wrong half — the
  # mistake this screen invites — shows up as a column of wrong pixels.
  def test_the_two_screens_draw_the_same_column
    tear_free = assert_emulator_loads_rom(assemble_rom(column_program(tear_free: true), name: "TFCOL"),
                                       frames: 6).frame_gba
    direct = assert_emulator_loads_rom(assemble_rom(column_program(tear_free: false), name: "DRCOL"),
                                    frames: 6).frame_gba

    differ = mismatched_pixels(direct, tear_free)

    assert_empty differ.first(8), "the two screens drew different pictures"
  end

  # A screen told which colors it shows was given a table its pictures were drawn against,
  # so a color outside it cannot be shown at all. The error names the picture, because
  # nobody typed the color — it arrived in the art.
  def test_a_picture_the_screen_was_not_given_names_that_picture
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true, colors: [Color.resolve(:black), Color.resolve(:red)]
      image :bars, width: 2, height: 4, data: BARS
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 0, height: 8 }
    end
    b.finalize_program

    err = assert_raises(VBlank::IR::Palette::Missing) { GBA.new.lower(b.program) }

    assert_match(/:bars/, err.message)
  end
end

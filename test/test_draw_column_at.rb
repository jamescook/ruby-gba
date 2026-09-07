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
  include GembaSupport

  # Four rows, each its own color, so a stretch is readable row by row.
  BARS = %i[red red green green blue blue white white].freeze
  NAMES = { RubyGBA::Color.resolve(:red) => :red, RubyGBA::Color.resolve(:green) => :green,
            RubyGBA::Color.resolve(:blue) => :blue, RubyGBA::Color.resolve(:white) => :white,
            0 => nil }.freeze

  def program(&block)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
    end
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def column_on_screen(run, x, from, to)
    (from...to).map { |y| NAMES.fetch(run.screen.pixel(x, y), :other) }
  end

  def test_a_column_stretched_to_twice_its_height_shows_each_row_twice
    run = Reference.new.run(program do
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 0, height: 8 }
    end, frames: 2)

    assert_equal %i[red red green green blue blue white white], column_on_screen(run, 10, 0, 8)
  end

  def test_a_column_squashed_to_half_its_height_drops_the_rows_between
    run = Reference.new.run(program do
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 0, height: 2 }
    end, frames: 2)

    assert_equal %i[red blue], column_on_screen(run, 10, 0, 2)
  end

  # A height the game works out is the whole point — a wall's height is never known while
  # building.
  def test_a_height_the_game_works_out_stretches_the_same_way
    run = Reference.new.run(program do
      tall = var :tall, 0
      game_loop do
        tall.set 8
        draw_column_at :bars, slice: 0, x: 10, top: 0, height: tall
      end
    end, frames: 2)

    assert_equal %i[red red green green blue blue white white], column_on_screen(run, 10, 0, 8)
  end

  # A wall you are nose-to-nose with is taller than the screen, and one at the far end of a
  # corridor has no height at all. Neither needs a test around it.
  def test_no_height_draws_nothing_and_a_column_past_the_screen_is_clipped
    run = Reference.new.run(program do
      game_loop do
        draw_column_at :bars, slice: 0, x: 10, top: 0, height: 0
        draw_column_at :bars, slice: 0, x: 12, top: -8, height: 24
        draw_column_at :bars, slice: 0, x: 14, top: 155, height: 40
      end
    end, frames: 2)

    assert_equal [nil, nil], column_on_screen(run, 10, 0, 2)
    # top: -8 of 24 means the first third is above the screen, so row 0 shows the picture's
    # middle rather than its first row.
    assert_equal :green, column_on_screen(run, 12, 0, 1).first
    refute_nil column_on_screen(run, 14, 158, 159).first, "the part still on screen is drawn"
  end

  # Many pictures live side by side in one, so a game with a hundred wall pictures needs no
  # runtime choosing — a slice past the end reads the last column rather than whatever is next
  # in memory.
  def test_a_slice_past_the_picture_is_held_to_its_last_column
    run = Reference.new.run(program do
      game_loop { draw_column_at :bars, slice: 99, x: 10, top: 0, height: 4 }
    end, frames: 2)

    assert_equal %i[red green blue white], column_on_screen(run, 10, 0, 4)
  end

  def test_a_picture_that_does_not_exist_says_how_to_make_one
    err = assert_raises(ArgumentError) do
      program { game_loop { draw_column_at :nope, slice: 0, x: 0, top: 0, height: 4 } }
    end

    assert_match(/image :nope/, err.message)
  end

  # A first-person view draws its columns in a LOOP, so this is the case that matters most, and
  # it was broken: a loop keeps its count in the console's registers unless the body needs them,
  # and a stretched column needs them twice over — it works in them, and it calls the divide
  # routine to find its step. Undeclared, the first column drew and the loop then walked off.
  def test_columns_drawn_in_a_loop_all_arrive
    prog = program do
      game_loop do
        repeat(8) { |c| draw_column_at :bars, slice: 0, x: c, top: 0, height: 4 }
      end
    end

    interp = Reference.new.run(prog, frames: 2)
    drawn = (0...8).count { |x| interp.screen.pixel(x, 0) == RubyGBA::Color.resolve(:red) }
    assert_equal 8, drawn, "the interpreter should draw every column"

    rom = ROM.assemble(GBA.new.lower(prog), title: "LOOP", code: "ALUP", maker: "01")
    gba = assert_gemba_loads_rom(rom, frames: 4)
    on_console = (0...8).count { |x| gba.pixel_gba(x, 0) == RubyGBA::Color.resolve(:red) }

    assert_equal 8, on_console, "the console should draw every column too"
  end

  # A depth record — what keeps a guard from showing through a wall — needs nothing new: a list
  # holds how far away each screen column ended up, and a condition gates the next draw. Worth
  # a test because it is the pattern a first-person view is built on.
  def test_a_column_can_be_gated_on_a_distance_kept_per_column
    prog = program do
      image :thing, width: 1, height: 2, data: %i[white white]
      depth = list :depth, capacity: 8
      col = var :col, 0
      repeat(8) { depth << 0 } # a list starts empty; a depth record needs its slots up front

      game_loop do
        repeat(8) do |c|
          far = var :_far, 0
          far.set 10
          (c >= 4).then { far.set 2 } # the right half is nearer than the thing
          depth[c] = far
          draw_column_at :bars, slice: 0, x: c, top: 0, height: 8
        end
        repeat(8) do |c|
          col.set c
          (depth[col] > 5).then { draw_column_at :thing, slice: 0, x: col, top: 2, height: 4 }
        end
      end
    end

    run = Reference.new.run(prog, frames: 2)
    seen = (0...8).map { |x| run.screen.pixel(x, 3) == RubyGBA::Color.resolve(:white) }

    assert_equal [true] * 4 + [false] * 4, seen,
                 "the thing shows over the far wall and is hidden by the near one"
  end

  # The two backends have to land every pixel in the same place, or the interpreter is no use
  # for debugging a renderer built on this.
  def test_the_console_draws_the_same_pixels_as_the_interpreter
    prog = program do
      tall = var :tall, 0
      game_loop do
        tall.set 40
        draw_column_at :bars, slice: 0, x: 10, top: 10, height: tall
        draw_column_at :bars, slice: 1, x: 12, top: 10, height: 2
        draw_column_at :bars, slice: 0, x: 14, top: 10, height: 0
        draw_column_at :bars, slice: 0, x: 16, top: -8, height: 24
        draw_column_at :bars, slice: 0, x: 18, top: 150, height: 40
        draw_column_at :bars, slice: 9, x: 20, top: 10, height: 8
      end
    end

    interp = Reference.new.run(prog, frames: 2)
    rom = ROM.assemble(GBA.new.lower(prog), title: "COLUMN", code: "ACOL", maker: "01")
    gba = assert_gemba_loads_rom(rom, frames: 4)

    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      interp.screen.pixel(x, y) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end

  # A STRIP IS ONE WALK. Its pixels all show the same picture column at the same height, so
  # asking for them one at a time works the same answer out that many times over. What it
  # draws has to be identical, which is what this pins.
  def test_a_strip_draws_what_the_same_pixels_drawn_one_at_a_time_draw
    apiece = program do
      game_loop { 3.times { |dx| draw_column_at :bars, slice: 0, x: 10 + dx, top: 4, height: 8 } }
    end
    strip = program do
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 4, height: 8, width: 3 }
    end

    one = Reference.new.run(apiece, frames: 2)
    many = Reference.new.run(strip, frames: 2)
    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      one.screen.pixel(x, y) == many.screen.pixel(x, y)
    end

    assert_empty differ.first(8), "a strip drew something different from its own pixels"
    assert_equal %i[red red green green blue blue white white], column_on_screen(many, 12, 4, 12)
  end

  # A strip hanging off the side of the screen keeps the part that is on it. This is the case
  # a first-person view meets only at the edges, and the one a shared walk could quietly get
  # wrong by drawing the whole strip or none of it.
  def test_a_strip_past_the_edge_keeps_the_part_that_is_on_screen
    run = Reference.new.run(program do
      game_loop do
        draw_column_at :bars, slice: 0, x: 238, top: 0, height: 4, width: 4
        draw_column_at :bars, slice: 0, x: -2, top: 0, height: 4, width: 4
      end
    end, frames: 2)

    assert_equal :red, column_on_screen(run, 239, 0, 1).first, "the pixel still on screen draws"
    assert_equal :red, column_on_screen(run, 0, 0, 1).first, "and at the other edge too"
    assert_nil run.screen.pixel(240, 0), "nothing past the right edge"
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

    run = Reference.new.run(prog, frames: 2)

    assert_equal %i[white white other other other other white white],
                 column_on_screen(run, 10, 0, 8).map { |c| c == :other ? :other : c }
    assert_equal RubyGBA::Color.resolve(:gray), run.screen.pixel(10, 3),
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
  include GembaSupport
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

  def lamp_program(tear_free:, art: LAMP)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: tear_free
      image(:lamp, "." => :transparent, "#" => :white) { art }
      tall = var :tall, 0
      game_loop do
        clear_screen :gray
        HEIGHTS.each_with_index do |height, n|
          tall.set height
          4.times do |slice|
            # Above the screen, on it, and running off the bottom.
            draw_column_at :lamp, slice: slice, x: (n * 4) + slice, top: 0, height: tall
            draw_column_at :lamp, slice: slice, x: (n * 4) + slice + 60, top: -30, height: tall
            draw_column_at :lamp, slice: slice, x: (n * 4) + slice + 120, top: 130, height: tall
          end
        end
      end
    end
    b.emit_pending_functions
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
end

# The same stretched column on the TEAR-FREE screen, which is the one a first-person view
# actually wants: it repaints the whole screen every frame, and that is what tears.
#
# This screen holds a NUMBER per pixel rather than a color, and refuses a lone byte — the
# smallest write covers a side-by-side pair. So every pixel is a read of its pair, a splice
# of its own half and a write back, and WHICH HALF depends on the column being even or odd.
# That is why the odd column has tests of its own here.
class TestDrawColumnAtTearFree < Minitest::Test
  include GembaSupport
  include Differential

  BARS = %i[red red green green blue blue white white].freeze

  # The same program on either screen, so the two can be held against each other.
  def column_program(tear_free:)
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
        at.set 31 # a column whose evenness cannot be proved while building
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
        at.set 200
        draw_column_at :bars, slice: 0, x: at, top: 100, height: 12, width: 3
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_the_console_draws_what_the_interpreter_draws
    assert_backends_agree(column_program(tear_free: true), frames: 3, name: "TFCOL")
  end

  # THE POINT OF THE WHOLE BEAD: a game that moves to the tear-free screen to stop the
  # flicker must get the same picture it had before. Every one of the cases above is
  # compared across the two screens, so an odd column spliced into the wrong half — the
  # mistake this screen invites — shows up as a column of wrong pixels.
  def test_the_two_screens_draw_the_same_column
    tear_free = assert_gemba_loads_rom(assemble_rom(column_program(tear_free: true), name: "TFCOL"),
                                       frames: 6).frame_gba
    direct = assert_gemba_loads_rom(assemble_rom(column_program(tear_free: false), name: "DRCOL"),
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
    b.emit_pending_functions

    err = assert_raises(RubyGBA::IR::Palette::Missing) { GBA.new.lower(b.program) }

    assert_match(/:bars/, err.message)
  end
end

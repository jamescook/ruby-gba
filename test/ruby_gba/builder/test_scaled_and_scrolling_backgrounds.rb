# frozen_string_literal: true

require "test_helper"

# A background that turns or resizes, BESIDE ordinary scrolling ones, on one screen.
#
# The console has three tile arrangements and the framework offered the two extremes:
# `screen :tiled` gives four scrolling layers and none of them can turn, `screen
# :rotozoom` gives one layer that turns and resizes and nothing else. The middle one —
# two scrolling layers plus one that turns — is the arrangement nearly every game that
# turns anything actually wants, because a turning layer is almost never the whole
# picture: a title where an object flies at the player over a backdrop, a map screen
# that spins inside a fixed frame, a road that banks under a sky and a status bar.
#
# Nothing in a program says which arrangement it wants. A background is one that turns
# because the program turns it, and the build picks the hardware that holds what was
# declared.
class TestScaledAndScrollingBackgrounds < Minitest::Test
  # A solid 8x8 tile of one colour, so a cell's colour is the whole assertion.
  def solid_tile(builder, name, color)
    builder.image(name, "#" => color) { "########\n" * 8 }
  end

  # Rows of cells with one mark in them, the rest blank.
  def marked_map(cols, rows, marks)
    grid = Array.new(rows) { Array.new(cols, " ") }
    marks.each { |(c, r), ch| grid[r][c] = ch }
    grid.map(&:join)
  end

  # THE ARRANGEMENT ITSELF: two ordinary scrolling layers and one that resizes, all on
  # one screen, all three showing. Built at the size it was drawn (1.0) so the picture
  # reads exactly as authored and each layer is judged by one pixel.
  def three_layer_program(scale: 1.0)
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    solid_tile(b, :i_green, :green)
    sky = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    rays = marked_map(30, 20, { [1, 1] => "$" })
    sword = marked_map(32, 32, { [2, 2] => "%" })
    b.instance_eval do
      tiles :t_sky,   "#" => :i_blue
      tiles :t_rays,  "$" => :i_red
      tiles :t_sword, "%" => :i_green
      background :sky,  tiles: :t_sky,  map: sky
      background :rays, tiles: :t_rays, map: rays
      background(:sword, tiles: :t_sword, map: sword).scale(scale)
      halt
    end
    b.emit_pending_functions
    b.program
  end

  def test_two_scrolling_layers_and_one_that_resizes_all_draw
    s = Reference.new.run(three_layer_program).screen
    assert_equal Color.resolve(:blue),  s.pixel(100, 100), "the backmost scrolling layer fills the screen"
    assert_equal Color.resolve(:red),   s.pixel(12, 12),   "the middle scrolling layer draws over it"
    assert_equal Color.resolve(:green), s.pixel(20, 20),   "the resizing layer draws over both"
  end

  # The layer really is resized, not merely drawn: at twice the size a mark two cells
  # from the top-left is drawn further out from the middle of the screen, which is what
  # this layer pivots on.
  def test_the_resizing_layer_is_actually_resized
    plain = Reference.new.run(three_layer_program(scale: 1.0)).screen
    zoomed = Reference.new.run(three_layer_program(scale: 2.0)).screen
    assert_equal Color.resolve(:green), plain.pixel(20, 20), "at its drawn size the mark is where it was drawn"
    refute_equal Color.resolve(:green), zoomed.pixel(20, 20), "at twice the size it has moved off that pixel"
  end

  # A scrolling layer keeps everything screen :tiled gives it while a resizing layer
  # shares the screen — the scroll is the one worth asserting, because it is the hardware
  # the resizing layer does NOT have.
  def test_a_scrolling_layer_still_scrolls_beside_a_resizing_one
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    rays = marked_map(30, 20, { [1, 1] => "$" })
    sword = marked_map(32, 32, {})
    b.instance_eval do
      tiles :t_rays,  "$" => :i_red
      tiles :t_sword, "#" => :i_blue
      moving = background :rays, tiles: :t_rays, map: rays
      background(:sword, tiles: :t_sword, map: sword).scale(1.0)
      game_loop do
        wait_vblank
        moving.scroll_by 8, 0 # one whole cell a frame, left
      end
    end
    b.emit_pending_functions
    # The scroll is applied at the frame boundary, so the moved picture is the SECOND
    # frame's — the same one frame of lag a scroll has with no resizing layer present.
    s = Reference.new.run(b.program, frames: 2).screen
    assert_equal Color.resolve(:red), s.pixel(4, 12), "the mark moved one cell left as the layer scrolled"
    refute_equal Color.resolve(:red), s.pixel(12, 12), "...and is no longer where it was drawn"
  end

  # THE WHOLE POINT IS THAT THE PLAIN LAYERS LOSE NOTHING, and swapping a map and
  # changing one cell are the two that touch a layer's cells rather than its registers —
  # the ones a different hardware arrangement could plausibly have broken. A game with a
  # turning title over rooms it walks between needs both.
  def test_a_plain_layer_keeps_show_map_and_set_tile_beside_a_resizing_one
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_red, :red)
    solid_tile(b, :i_green, :green)
    solid_tile(b, :i_blue, :blue)
    hall = marked_map(30, 20, {}).map { |row| row.tr(" ", "R") }
    cave = marked_map(30, 20, {}).map { |row| row.tr(" ", "G") }
    square = marked_map(32, 32, {})
    b.instance_eval do
      tiles :t, "R" => :i_red, "G" => :i_green
      tiles :t_spin, "#" => :i_blue
      rooms = background :rooms, tiles: :t, map: { hall: hall, cave: cave }
      background(:spin, tiles: :t_spin, map: square).scale(1.0)
      game_loop do
        wait_vblank
        rooms.show_map :cave
        rooms.set_tile 0, 0, "R"
      end
    end
    b.emit_pending_functions
    s = Reference.new.run(b.program, frames: 3).screen
    assert_equal Color.resolve(:green), s.pixel(44, 44), "show_map handed the plain layer the other room"
    assert_equal Color.resolve(:red),   s.pixel(4, 4),   "...and set_tile put one of its cells back"
  end

  # A SEE-THROUGH LAYER IS THE OTHER THING screen :tiled gives that this must not cost,
  # because it is the half of a title screen that the turning piece flies over: rays or
  # mist blended over a backdrop while something zooms in front of them.
  def test_a_see_through_layer_still_shows_through_beside_a_resizing_one
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :behind, :water, :front
    end
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    square = marked_map(32, 32, {})
    b.instance_eval do
      tiles :t_blue, "#" => :i_blue
      tiles :t_red,  "#" => :i_red
      layer(:behind) { background :deep, tiles: :t_blue, map: full }
      layer(:water, transparency: 50) { background :top, tiles: :t_red, map: full }
      layer(:front) { background(:spin, tiles: :t_blue, map: square).scale(1.0) }
      halt
    end
    b.emit_pending_functions
    got = Reference.new.run(b.program).screen.pixel(100, 100)
    refute_equal Color.resolve(:red),  got, "the see-through layer is not drawn solid"
    refute_equal Color.resolve(:blue), got, "...nor is the layer behind it left uncovered"
    assert_equal see_through_red_over_blue, got, "half of each, exactly as with no turning layer present"
  end

  # What half red over blue comes out as — measured from the same program with the
  # turning layer left out, so this pins the blend to what screen :tiled already did
  # rather than to arithmetic restated here.
  def see_through_red_over_blue
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :behind, :water
    end
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    b.instance_eval do
      tiles :t_blue, "#" => :i_blue
      tiles :t_red,  "#" => :i_red
      layer(:behind) { background :deep, tiles: :t_blue, map: full }
      layer(:water, transparency: 50) { background :top, tiles: :t_red, map: full }
      halt
    end
    b.emit_pending_functions
    Reference.new.run(b.program).screen.pixel(100, 100)
  end

  # A LAYER THAT TURNS HAS NO SCROLL OF ITS OWN, and a program can say the two in either
  # order. Scrolling first and turning second is the order that would otherwise pass the
  # build and quietly stop the scroll working.
  def test_scrolling_a_background_and_then_resizing_it_is_a_friendly_error
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    square = marked_map(32, 32, {})
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        tiles :t, "#" => :i_blue
        bg = background :both, tiles: :t, map: square
        game_loop { bg.scroll_by 1, 0 }
        bg.scale(2.0)
      end
    end
    assert_match(/scrolls background :both/, err.message, "it names the background that says both")
    assert_match(/stop moving :both that way/, err.message, "...and a way out that is not the call that raised")
  end

  # THE COUNT IS SMALLER ON THIS ARRANGEMENT, and that is the thing a program can get
  # wrong. Two scrolling layers plus one that resizes is what the console holds; a third
  # scrolling layer beside a resizing one fits no arrangement at all, so it is a friendly
  # error naming both counts rather than a layer quietly not drawn.
  def test_too_many_scrolling_layers_beside_a_resizing_one_is_a_friendly_error
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    plain = marked_map(30, 20, {})
    square = marked_map(32, 32, {})
    b.instance_eval do
      tiles :t, "#" => :i_blue
      background :one,   tiles: :t, map: plain
      background :two,   tiles: :t, map: plain
      background :three, tiles: :t, map: plain
      background(:spin, tiles: :t, map: square).scale(1.0)
      halt
    end
    b.emit_pending_functions
    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { assemble_rom(b.program, name: "TOOMANY") }
    assert_match(/shows 3 scrolling backgrounds at one time/, err.message, "it says how many are on screen at once")
    assert_match(/shows 2 scrolling backgrounds at one time/, err.message, "...and how many fit beside a resizing one")
    assert_match(/:spin/, err.message, "...and which background costs the other two")
  end

  # TWO SCREENS THAT TAKE TURNS EACH HOLD THEIR OWN LAYERS. A title that zooms, handing
  # over to a game with four scrolling layers, is two arrangements one after the other —
  # the console is never in both at once, so the title's turning layer costs the game
  # nothing. Counting them together would refuse a program that has always built.
  def test_a_turning_title_screen_does_not_cost_a_tiled_scene_its_layers
    b = Builder.new
    solid_tile(b, :i_blue, :blue)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    square = marked_map(32, 32, {}).map { |row| row.tr(" ", "#") }
    b.instance_eval do
      var :state, 0
      tiles :t, "#" => :i_blue
      scene(:title) do
        screen :rotozoom
        background(:turner, tiles: :t, map: square).scale(1.0)
      end
      scene(:play) do
        screen :tiled
        background :one,   tiles: :t, map: full
        background :two,   tiles: :t, map: full
        background :three, tiles: :t, map: full
      end
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.emit_pending_functions
    assemble_rom(b.program, name: "TURNTITL") # it builds; before it counted the four together
  end

  # Bending a background's rows gives each row its own sideways scroll, so it is a scroll
  # and a layer that turns has none. Worth its own test because it is the shape that was
  # silently accepted and did nothing.
  def test_bending_the_rows_of_a_resizing_background_is_a_friendly_error
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    square = marked_map(32, 32, {})
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        tiles :t, "#" => :i_blue
        bg = background :spin, tiles: :t, map: square
        bg.scale(1.0)
        bg.scroll_each_row { |row| row }
      end
    end
    assert_match(/no scroll to bend/, err.message)
  end

  # ...and the other way round, which a program is just as likely to write.
  def test_bending_rows_and_then_resizing_is_a_friendly_error_too
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    square = marked_map(32, 32, {})
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        tiles :t, "#" => :i_blue
        bg = background :spin, tiles: :t, map: square
        bg.scroll_each_row { |row| row }
        bg.scale(1.0)
      end
    end
    assert_match(/bends the rows of background :spin/, err.message)
  end

  # THE STACK DECIDES WHERE THE TURNING LAYER SITS, like anything else the console
  # redraws — it is not pinned in front just because of the hardware it uses. A layer
  # declared behind a solid one is covered by it.
  def test_the_stack_can_put_the_resizing_layer_behind_a_scrolling_one
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :under, :over
    end
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    square = marked_map(32, 32, {}).map { |row| row.tr(" ", "#") }
    b.instance_eval do
      tiles :t_spin, "#" => :i_blue
      tiles :t_flat, "#" => :i_red
      layer(:under) { background(:spin, tiles: :t_spin, map: square).scale(1.0) }
      layer(:over)  { background :flat, tiles: :t_flat, map: full }
      halt
    end
    b.emit_pending_functions
    assert_equal Color.resolve(:red), Reference.new.run(b.program).screen.pixel(100, 100),
                 "the scrolling layer in front covers the resizing one behind it"
  end

  # Two backgrounds that resize is still what it always was: the console has one such
  # layer, whatever else is on screen.
  def test_two_resizing_layers_is_still_a_friendly_error
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    square = marked_map(32, 32, {})
    b.instance_eval do
      tiles :t, "#" => :i_blue
      background(:a, tiles: :t, map: square).scale(1.0)
      background(:b, tiles: :t, map: square).scale(1.0)
      halt
    end
    b.emit_pending_functions
    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { assemble_rom(b.program, name: "TWOSPIN") }
    assert_match(/turns or resizes 2 backgrounds/, err.message, "it says how many were declared")
    assert_match(/can turn 1 background/, err.message, "...and how many the console turns")
  end

  # --- Hardware: the console shows the same three layers ---

  def test_the_console_shows_all_three_layers
    v = assert_emulator_loads_rom(assemble_rom(three_layer_program, name: "MIXEDBG3"), frames: 4)
    assert v.blue?(100, 100),  "the backmost scrolling layer fills the screen"
    assert v.red?(12, 12),     "the middle scrolling layer draws over it"
    assert v.green?(20, 20),   "the resizing layer draws over both"
  end

  # ...and it is really the console's mixed arrangement doing it, read off the display
  # register on the running cartridge rather than inferred from the picture. Worth
  # asserting on its own: three layers could look right while one was being drawn some
  # other way, and the whole change is which arrangement the build picks.
  def test_the_console_is_put_in_the_arrangement_that_holds_a_turning_layer
    mixed = assert_emulator_loads_rom(assemble_rom(three_layer_program, name: "MIXEDBG4"), frames: 4)
    assert_equal 1, mixed.mem16(RubyGBA::Cartridge::Constants::REG_DISPCNT) & DISPLAY_MODE,
                 "two scrolling layers and one that turns is the console's second arrangement"

    plain = assert_emulator_loads_rom(assemble_rom(scrolling_only_program, name: "PLAINBG4"), frames: 4)
    assert_equal 0, plain.mem16(RubyGBA::Cartridge::Constants::REG_DISPCNT) & DISPLAY_MODE,
                 "a game that turns nothing keeps the arrangement with four scrolling layers"
  end

  # The low three bits of the display register say which arrangement the console is in.
  DISPLAY_MODE = 0x7

  # The same three layers with nothing resized — the control for the assertion above.
  def scrolling_only_program
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    b.instance_eval do
      tiles :t, "#" => :i_blue
      background :sky,  tiles: :t, map: full
      background :rays, tiles: :t, map: full
      halt
    end
    b.emit_pending_functions
    b.program
  end
end

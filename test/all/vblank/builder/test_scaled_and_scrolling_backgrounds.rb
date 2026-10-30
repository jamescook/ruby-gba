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
#
# What the Advance's cartridge shows for the three layers, and which arrangement its display is
# put in, is read in the emulator in
# test/lowering/gba/vblank/builder/test_scaled_and_scrolling_backgrounds_cartridge.rb, which
# draws its games with the pieces kept here in ScaledAndScrollingBackgroundsGames.
module ScaledAndScrollingBackgroundsGames
  # A solid 8x8 tile of one colour, so a cell's colour is the whole assertion.
  private def solid_tile(builder, name, color)
    builder.image(name, "#" => color) { "########\n" * 8 }
  end

  # Rows of cells with one mark in them, the rest blank.
  private def marked_map(cols, rows, marks)
    grid = Array.new(rows) { Array.new(cols, " ") }
    marks.each { |(c, r), ch| grid[r][c] = ch }
    grid.map(&:join)
  end
end

class TestScaledAndScrollingBackgrounds < Minitest::Test
  include ScaledAndScrollingBackgroundsGames

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
    b.finalize_program
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { assemble_rom(b.program, name: "TOOMANY") }
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
    b.finalize_program
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
    b.finalize_program
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { assemble_rom(b.program, name: "TWOSPIN") }
    assert_match(/turns or resizes 2 backgrounds/, err.message, "it says how many were declared")
    assert_match(/can turn 1 background/, err.message, "...and how many the console turns")
  end
end

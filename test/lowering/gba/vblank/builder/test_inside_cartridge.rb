# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_inside"

# A PART OF THE SCREEN THAT DRAWING STAYS INSIDE, on the Advance's own cartridge. The interpreter
# asks one question at the one place a cell is painted, and the console works the same edges out
# again inside every shape, so the two agreeing over the whole screen is the proof — and that
# reads the cartridge in the emulator. What an area does, asked of every run, is in
# test/all/vblank/builder/test_inside.rb, which keeps the games both files play in InsideGames;
# what only the Advance's runs play is in test/console/gba/vblank/builder/test_inside_on_the_advance.rb.
class TestInsideCartridge < Minitest::Test
  include InsideGames

  # AN AREA HOLDS DRAWING, NOT THE DISPLAY. The picture is read at a frame boundary, while the
  # area is still open, and compared with the console's whole: the window stands still, so every
  # frame shows the same picture. Inside the area's right edge the window shows cells from
  # outside it, and outside the area it shows the red square moved by the window.
  def test_the_whole_picture_shows_while_a_frame_ends_inside_an_area
    seen, = picture_at_frame_boundary
    rom = ROM.assemble(GBA.new.lower(frame_ending_inside_area), title: "INSIDE3", code: "AIN3", maker: "01")
    console = assert_emulator_loads_rom(rom, frames: 6)

    differ = every_pixel.reject { |x, y| seen[(y * 240) + x] == console.pixel_gba(x, y) }
    assert_empty differ.first(8), "read at a frame boundary inside the area, these pixels differ from the console"
  end

  # KEPT LIGHT ON PURPOSE. This screen is drawn straight into the one the console is showing, so
  # a frame that takes longer than a frame is read half finished — and since the drawing runs
  # left to right, what that looks like is the right-hand side disagreeing. That is a measure of
  # how far the console GOT, not of what it draws, and it will happily fail a correct backend.
  # A dozen short columns finish inside a frame with room to spare.
  def test_the_console_clips_where_the_interpreter_clips
    prog = program do
      tall = var :tall, 0
      game_loop do
        clear_screen :black
        tall.set! 90
        inside(*AREA) do
          dma_fill_rect 0, 0, 240, 160, :green
          (0...240).step(20) { |x| draw_column_at :bars, slice: 0, x: x, top: -20, height: tall }
          draw_column_at :bars, slice: 1, x: 38, top: 0, height: 60, width: 4
          draw_column_at :bars, slice: 1, x: 156, top: 0, height: 60, width: 4
          fill_rect 0, 0, 240, 8, :white
          pixel 10, 10, :blue
          pixel 100, 100, :blue
        end
        dma_fill_rect 0, 150, 240, 10, :blue
      end
    end

    assert_cartridge_matches_interpreter(prog, "INSIDE", "AIN1")
  end

  # ...and on the tear-free screen, which is a different lowering with its own clipping and the
  # one a first-person view actually draws on.
  def test_the_tear_free_console_clips_where_the_interpreter_clips
    prog = program(tear_free: true) do
      tall = var :tall, 0
      game_loop do
        tall.set! 240
        inside(*AREA) do
          dma_fill_rect 0, 0, 240, 160, :green
          (0...240).step(6) { |x| draw_column_at :bars, slice: 0, x: x, top: -40, height: tall }
          draw_column_at :bars, slice: 1, x: 38, top: 0, height: 60, width: 4
          draw_column_at :bars, slice: 1, x: 156, top: 0, height: 60, width: 4
        end
        dma_fill_rect 0, 150, 240, 10, :blue
      end
    end

    assert_cartridge_matches_interpreter(prog, "INSIDE2", "AIN2")
  end

  private def assert_cartridge_matches_interpreter(prog, title, code)
    interp = game_player.run(prog, frames: 3)
    rom = ROM.assemble(GBA.new.lower(prog), title: title, code: code, maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 6)

    differ = every_pixel.reject { |x, y| (interp.screen.pixel(x, y) || 0) == gba.pixel_gba(x, y) }

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end
end

# frozen_string_literal: true

require "test_helper"

# The tests of test_inside.rb whose games paint more colours into one 8×8 square of the screen
# than a Game Boy Color's square holds (four, black among them), so they play on the Advance's
# runs alone. Those the Advance's cartridge is held to in the emulator are in
# test/lowering/gba/vblank/builder/test_inside_cartridge.rb.
class TestInsideOnTheAdvance < Minitest::Test

  BARS = %i[red red green green blue blue white white].freeze
  AREA = [40, 20, 120, 80].freeze # x, y, w, h — off every edge of the screen

  private def program(mode: :bitmap, tear_free: false, &block)
    b = Builder.new
    colours = tear_free ? [:black, :red, :green, :blue, :white, :yellow] : nil
    b.instance_eval do
      tear_free ? (screen mode, tear_free: true, colors: colours) : (screen mode)
      image :bars, width: 2, height: 4, data: BARS
    end
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def inside?(x, y)
    ax, ay, aw, ah = AREA
    x >= ax && x < ax + aw && y >= ay && y < ay + ah
  end

  # A stretched column is the one this exists for: it is the verb whose height a game works out,
  # so it is the one that draws far past an edge and pays for every row of it.
  def test_a_stretched_column_stops_at_the_edges_of_the_area
    run = game_player.run(program do
      game_loop do
        clear_screen :black
        inside(*AREA) do
          (0...240).step(4) { |x| draw_column_at :bars, slice: 0, x: x, top: -40, height: 240 }
        end
      end
    end, frames: 2)

    painted = every_pixel.select { |x, y| run.screen.pixel(x, y) != VBlank::Graphics::Color.resolve(:black) }

    refute_empty painted, "the columns should draw something"
    assert_empty painted.reject { |x, y| inside?(x, y) }.first(8), "and nothing outside the area"
  end

  # An area CLIPS, it does not move: a pixel keeps the coordinates it was given, so an area can
  # be put around drawing that already works and only what fell outside changes.
  def test_an_area_does_not_move_what_it_keeps
    plain = program { game_loop { draw_column_at :bars, slice: 0, x: 100, top: 40, height: 32 } }
    held = program do
      game_loop { inside(*AREA) { draw_column_at :bars, slice: 0, x: 100, top: 40, height: 32 } }
    end

    one = game_player.run(plain, frames: 2)
    two = game_player.run(held, frames: 2)
    differ = every_pixel.reject { |x, y| one.screen.pixel(x, y) == two.screen.pixel(x, y) }

    assert_empty differ.first(8), "a shape wholly inside the area draws exactly where it did"
  end

  private def every_pixel = @every_pixel ||= (0...240).to_a.product((0...160).to_a)
end

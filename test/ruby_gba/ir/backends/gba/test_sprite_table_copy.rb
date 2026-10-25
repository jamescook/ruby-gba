# frozen_string_literal: true

require "test_helper"
require "differential"

# MORE SPRITES THAN THE CONSOLE HAS PLACES FOR, AS LONG AS NO MORE SHOW AT ONCE.
#
# The console draws its sprites from a table of 128 places. A pool keeps a place for every thing
# it can hold, so three pools of sixty need 180 places although a room shows a handful. Such a
# cartridge keeps its sprites in a bigger copy of the table, and before each frame copies the
# places that show something into the console's, front to back — so what has to fit is one
# frame's sprites, as on the console's own games, and the order they are drawn in is the order
# they were declared in.
class TestSpriteTableCopy < Minitest::Test
  include Differential

  COLORS = %i[red green blue].freeze

  # Three pools of +capacity+ eight-pixel squares, red, green and blue, declared in that order,
  # so blue is drawn in front. Each spawns +live+ things, four pixels further right than the
  # last pool's, in rows of twenty ten pixels apart.
  private def crowd(live:, capacity: 60)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      pools = COLORS.map do |color|
        image(:"#{color}_square", "#" => color) { "########\n" * 8 }
        pool :"#{color}s", x: 0, y: 0, capacity: capacity, image: :"#{color}_square"
      end
      started = var :started, 0
      game_loop do
        (started == 0).then do
          pools.each_with_index do |things, k|
            live.times { |n| things.spawn(x: 20 + (k * 4) + ((n % 20) * 10), y: 20 + ((n / 20) * 10)) }
          end
          started.set! 1
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # The places come to 180, and the cartridge builds and draws what the interpreter draws:
  # where two squares overlap, the pool declared later is in front.
  def test_pools_holding_more_than_the_console_has_places_draw_as_the_interpreter_does
    assert_backends_agree(crowd(live: 2), frames: 6, name: "CROWD")
  end

  # Every row the console shows is named for the sprite it came from, as on any cartridge.
  def test_each_row_shown_is_named_for_its_sprite
    rom = assemble_rom(crowd(live: 2), name: "NAMED")
    names = assert_emulator_loads_rom(rom, frames: 6).sprites.map(&:name)

    assert_equal({ reds: 2, greens: 2, blues: 2 }, names.tally, "two of each colour, each named for its pool")
  end

  # MORE SHOWING THAN THE CONSOLE HAS PLACES: the frontmost 128 are drawn, and the cartridge
  # counts the rest each frame, which a profile says. Fifty of each colour is 150: the blues and
  # the greens, in front, all show, and 28 of the reds do.
  def test_a_frame_with_more_showing_than_places_draws_the_front_128_and_counts_the_rest
    rom = assemble_rom(crowd(live: 50), name: "TOOMANY")
    rows = assert_emulator_loads_rom(rom, frames: 6).sprites
    profile = RubyGBA::Diagnostics::Profiler.run(rom, frames: 10, picture: false)

    assert_equal({ blues: 50, greens: 50, reds: 28 }, rows.map(&:name).tally, "the reds, furthest back, are left out")
    assert_equal 22 * 10, profile.sprites_left_out, "22 left out on each of the ten frames measured"
  end
end

# frozen_string_literal: true

require "test_helper"
require "differential"

# WHAT A STRETCHED COLUMN COSTS on the console, which is most of a first-person view's frame:
# every wall strip, every thing standing in a room and the gun go through the one walk.
#
# Each claim here is measured by running the cartridge, never by reading the code it emits,
# and each comes with the same picture drawn on the interpreter, since none of them is allowed
# to change a pixel.
class TestColumnWalkCost < Minitest::Test
  include EmulatorSupport
  include Differential

  STRIPS = 60

  # A picture with see-through pixels in it, whose first column is solid all the way down: drawn
  # as that column, it is one stretch of pixels as tall as the strip, walked as a see-through
  # picture is walked.
  SEE_THROUGH_BARS = %i[red transparent green transparent blue transparent white transparent] * 2

  private def strips_program(heights, see_through: false)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      if see_through
        image :bars, width: 2, height: 8, data: SEE_THROUGH_BARS, transparent: true
      else
        image :bars, width: 2, height: 8, data: %i[red red green green blue blue white white] * 2
      end
      tall = var :tall, 0
      game_loop do
        clear_screen :gray
        heights.each_with_index do |height, x|
          tall.set! height
          draw_column_at :bars, slice: 0, x: x * 2, top: 10, height: tall
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def profile_of(program, title)
    backend = GBA.new
    machine_code = backend.lower(program)
    rom = VBlank::Cartridge::ROM.assemble(machine_code, title: title, built: backend.build_record(program))
    VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
  end

  # WHAT ONE SCREEN ROW OF A STRIP COSTS, in instructions: the same strips drawn twice as tall,
  # and the difference shared out over the rows that were added. Everything else in the two
  # frames is the same, so it cancels, and the profiler counts every instruction it ran.
  #
  # Both have to finish every pass inside a frame. One that ran over would spill into the next
  # frame and run FEWER instructions a frame, which would read as a cheaper row.
  private def instructions_per_row(title, see_through: false)
    short = profile_of(strips_program([40] * 20, see_through: see_through), "#{title}S")
    tall = profile_of(strips_program([80] * 20, see_through: see_through), "#{title}T")
    refute tall.dropping_frames?, "the taller strips ran over a frame, so the count means nothing"
    (tall.samples_per_frame - short.samples_per_frame) / (20 * 40)
  end

  private def divide_samples(result)
    result.lines.find { |line| line.name == VBlank::IR::Backends::GBA::Divide::ROUTINE }&.samples || 0
  end

  # A THING ON SCREEN IS MANY STRIPS OF ONE HEIGHT, and the step down the picture depends only
  # on that height and the picture's own. So once the first strip of a height has worked its
  # step out, a strip of the same height uses it again and does not divide. The profile starts
  # once the game has settled, so the one divide on the very first frame is behind it.
  def test_strips_of_one_height_do_not_divide_again
    require_emulator!
    result = profile_of(strips_program([40] * STRIPS), "ONESTEP")

    assert_equal 0, divide_samples(result), "strips of one height must not divide again"
  end

  # ...and a strip of a new height still divides, so the step is never one left over from
  # another height.
  def test_strips_of_changing_heights_still_divide
    require_emulator!
    result = profile_of(strips_program([40, 41] * (STRIPS / 2)), "TWOSTEPS")

    assert_operator divide_samples(result), :>, 0
  end

  # A ROW OF A STRIP ON THE TEAR-FREE SCREEN: read the picture's number for that row, splice it
  # into its half of the pair it shares, step on, and go round. A picture drawn as columns is
  # kept column by column, so its number for a row is one load with no multiply; nothing is
  # counted that the walk never reads; and the loop is tested once a row, at the bottom.
  def test_a_row_of_a_strip_on_the_tear_free_screen_is_nine_instructions
    require_emulator!

    assert_operator instructions_per_row("ROW"), :<=, 9.0
  end

  # A SEE-THROUGH PICTURE'S ROW COSTS WHAT A SOLID ONE'S DOES. The walk visits only the stretches
  # of a column that hold pixels, and each stretch's first and last screen rows are worked out
  # exactly, so every row it reaches has a pixel and none is asked whether it is see-through.
  def test_a_row_of_a_see_through_strip_costs_what_a_solid_one_does
    require_emulator!

    assert_operator instructions_per_row("SEE", see_through: true), :<=, 9.0
  end

  # EXACT ENDS, AT EVERY HEIGHT. Turning a picture row into a screen row divides, and a stretch
  # that came out a row short at one height would lose that row there and nowhere else, while
  # one a row long would paint a see-through pixel. So a picture of stretches, at a height that
  # is not a power of two, is drawn at every height from one row to well past the screen, and
  # at tops above the screen, on it and running off the bottom.
  #
  # The tallest are the ones a player meets nose to nose with a thing, where the guess at each
  # end is furthest out — and the last is so tall that its step down the picture is nothing at
  # all, so every row shows the picture's first row.
  SWEEP_HEIGHTS = ((1..64).to_a + [77, 100, 128, 159, 160, 161, 200, 255, 300, 400, 777, 1200, 5000,
                                    70_000, 400_000, 1_000_000]).freeze
  SWEEP_TOPS = [0, -40, 100].freeze
  STRETCHES = <<~ART
    #.#
    #..
    ...
    ..#
    .##
    ...
    ...
    #..
    ...
    ..#
    ##.
  ART

  def test_exact_stretch_ends_draw_what_the_interpreter_draws_at_every_height
    assert_backends_agree(sweep_program(tear_free: true), frames: 3, name: "EXACTEND")
  end

  # A pass of this takes the direct screen more than a frame, so the console is given frames
  # enough for a few of them. Its one page is cleared once and every pass paints the same
  # picture, so whichever pass it is read in shows the whole of it.
  def test_exact_stretch_ends_on_the_direct_screen_too
    assert_backends_agree(sweep_program(tear_free: false), frames: 1, console_frames: 14, name: "EXACTDIR")
  end

  # ...and strips wider than a pixel, hanging off either edge of the screen, which walk a copy
  # of the rows that asks each pixel whether it is on the screen.
  private def sweep_program(tear_free:)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: tear_free
      image(:marks, "." => :transparent, "#" => :white) { STRETCHES }
      tall = var :tall, 0
      # The direct screen is one page, so it is cleared once and every pass paints the same
      # picture over it: read part way through a pass, it still shows all of it. The tear-free
      # screen has two pages and shows only a finished one, so it clears each pass.
      clear_screen :gray unless tear_free
      game_loop do
        clear_screen :gray if tear_free
        SWEEP_HEIGHTS.each_with_index do |height, n|
          tall.set! height
          3.times do |slice|
            draw_column_at :marks, slice: slice, x: (n * 3) + slice, top: SWEEP_TOPS[n % 3], height: tall
          end
        end
        [[237, 13, 20], [-2, 777, -300], [236, 161, 90]].each do |x, height, top|
          tall.set! height
          draw_column_at :marks, slice: 0, x: x, top: top, height: tall, width: 5
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_reusing_a_step_draws_what_the_interpreter_draws
    assert_backends_agree(strips_program(([40] * 10) + [41, 41, 40, 7, 7, 300, 300, 40]),
                          frames: 3, name: "STEPPIC")
  end

  # The step is the PICTURE'S height over the strip's, so two pictures of different heights
  # drawn at one strip height take different steps, and neither may take the other's.
  def test_pictures_of_different_heights_at_one_strip_height_keep_their_own_steps
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      image :short, width: 1, height: 4, data: %i[red green blue white]
      image :tall, width: 1, height: 12, data: %i[red green blue white] * 3
      tall = var :tall, 0
      game_loop do
        clear_screen :gray
        tall.set! 24
        20.times do |x|
          draw_column_at x.even? ? :short : :tall, slice: 0, x: x * 2, top: 10, height: tall
        end
      end
    end
    b.finalize_program

    assert_backends_agree(b.program, frames: 3, name: "TWOPICS")
  end

  # A TIMER'S TICK CAN INTERRUPT A STRIP between reading the kept step and the numbers it came
  # from, so in a game whose tick draws a stretched column every strip divides, as before.
  def test_a_game_whose_timer_draws_a_column_divides_for_every_strip
    require_emulator!
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      image :bars, width: 2, height: 8, data: %i[red red green green blue blue white white] * 2
      tall = var :tall, 0
      clock = timer :clock, per_second: 30
      clock.on_tick { draw_column_at :bars, slice: 0, x: 200, top: 0, height: 20 }
      game_loop do
        clear_screen :gray
        tall.set! 40
        STRIPS.times { |x| draw_column_at :bars, slice: 0, x: x * 2, top: 10, height: tall }
      end
    end
    b.finalize_program

    assert_operator divide_samples(profile_of(b.program, "TICKSTEP")), :>, 0
  end
end

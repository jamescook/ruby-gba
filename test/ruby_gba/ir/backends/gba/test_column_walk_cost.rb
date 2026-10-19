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

  private def strips_program(heights)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      image :bars, width: 2, height: 8, data: %i[red red green green blue blue white white] * 2
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
    rom = RubyGBA::Cartridge::ROM.assemble(machine_code, title: title, built: backend.build_record(program))
    RubyGBA::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
  end

  # WHAT ONE SCREEN ROW OF A STRIP COSTS, in instructions: the same strips drawn twice as tall,
  # and the difference shared out over the rows that were added. Everything else in the two
  # frames is the same, so it cancels, and the profiler counts every instruction it ran.
  #
  # Both have to finish every pass inside a frame. One that ran over would spill into the next
  # frame and run FEWER instructions a frame, which would read as a cheaper row.
  private def instructions_per_row(title)
    short = profile_of(strips_program([40] * 20), "#{title}S")
    tall = profile_of(strips_program([80] * 20), "#{title}T")
    refute tall.dropping_frames?, "the taller strips ran over a frame, so the count means nothing"
    (tall.samples_per_frame - short.samples_per_frame) / (20 * 40)
  end

  private def divide_samples(result)
    result.lines.find { |line| line.name == RubyGBA::IR::Backends::GBA::Divide::ROUTINE }&.samples || 0
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

# frozen_string_literal: true

require "test_helper"

# A game for the Game Boy Color played as Ruby, checked against the interpreter on every frame. The
# Ruby lowering's run plays every other test as the Advance; these hold that nothing of the
# Advance's is left fixed in the runtime, so a game for a smaller console is played as that console.
class TestRubyColorGames < Minitest::Test
  Ruby = VBlank::IR::Backends::Ruby
  CheckedRun = Ruby::CheckedRun
  HALF_PAST = Time.new(2026, 10, 22, 21, 7, 5) + Rational(1, 2)

  # The program the block builds, for +console+.
  private def program_of(console = :gbc, &block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program.copy.tap { |copy| copy.console = console }
  end

  # The Color's screen is 160 by 144: a square in its far corner is on the screen, and is drawn
  # where the interpreter draws it.
  def test_a_color_game_draws_to_the_colors_screen
    program = program_of do
      game_loop do
        clear_screen :blue
        fill_rect 156, 140, 4, 4, :red
      end
    end

    run = CheckedRun.new.run(program, frames: 3)

    assert_equal Color.resolve(:red), run.screen.pixel(159, 143)
    assert_nil run.screen.pixel(160, 143)
  end

  # A background bent row by row is worked out for each of the Color's 144 rows and no more: the
  # block counts how many times it ran, and the count is checked against the interpreter's.
  def test_a_color_game_bends_each_row_of_its_screen
    program = program_of do
      screen :tiled
      image :reed, "|" => :white, "~" => :blue, "." => :transparent do "~|~~....\n" * 8 end
      tiles :water, "~" => :reed
      water = background :water, tiles: :water, map: ["~ ~~ ~~~ ~~~~"] * 20
      rows_worked_out = var :rows_worked_out, 0
      water.scroll_each_row do |row|
        rows_worked_out.add! 1
        row % 8
      end
      game_loop { wait_vblank }
    end

    run = CheckedRun.new.run(program, frames: 2)

    assert_operator run[:rows_worked_out], :>, 0
    assert_equal 0, run[:rows_worked_out] % 144, "every frame works out the Color's 144 rows"
  end

  # A HISS FASTER THAN THE ADVANCE HANDS ITS VOICES TO THE SPEAKER. The Advance looks at the noise
  # voice 32,768 times a second and holds what it saw until the next look, which is longer than a
  # sample, so neighbouring samples are alike more often than two coin tosses would be. The Color's
  # speaker is handed every step of the hiss, so its neighbours are alike about half the time.
  def test_a_fast_hiss_is_heard_step_for_step_on_the_color
    color = Ruby::HeadlessRun.new.recording_sound(only: 4).run(hissing_program(:gbc), frames: 4).sound
    advance = Ruby::HeadlessRun.new.recording_sound(only: 4).run(hissing_program(:gba), frames: 4).sound

    assert_operator neighbours_alike(color), :<, 0.58
    assert_operator neighbours_alike(advance), :>, 0.58
  end

  # A high hiss from the second frame on, for +console+.
  private def hissing_program(console)
    program_of(console) do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 1).then { noise pitch: :high, volume: 15 }
      end
    end
  end

  # Of every two neighbouring samples while the hiss sounds, the share that stand the same way.
  private def neighbours_alike(samples)
    sounding = samples.reject(&:zero?)
    pairs = sounding.each_cons(2).to_a
    pairs.count { |a, b| (a > 0) == (b > 0) }.fdiv(pairs.size)
  end

  # The Color's clock keeps no date, so before the game sets it, it reads as never set.
  def test_a_color_games_clock_reads_as_never_set_until_the_game_sets_it
    program = program_of do
      now = clock
      set = var :set, -1
      game_loop { now.set?.then { set.set! 1 }.else { set.set! 0 } }
    end

    assert_equal 0, CheckedRun.new.clock_at(HALF_PAST).run(program, frames: 3)[:set]
  end

  # A clock started half way through a second turns over half a second on, counted in the Color's
  # frames: the part of a second it starts at is handed over in the Color's cycles, which are not
  # the Advance's.
  def test_a_color_games_clock_turns_over_when_the_interpreters_does
    run = CheckedRun.new.clock_at(HALF_PAST).run(setting_program, frames: 40)

    assert_equal [1, 1], [run[:set], run[:second]]
  end

  # A game that sets the clock on its first pass, and keeps the second and whether the clock was
  # set, every pass.
  private def setting_program
    program_of do
      now = clock
      passes = var :passes, 0
      second = var :second, -1
      set = var :set, -1
      game_loop do
        (passes == 0).then { now.set_to(year: 2030, month: 6, day: 15, hour: 12, minute: 0, second: 0) }
        second.set! now.second
        set.set! 0
        now.set?.then { set.set! 1 }
        passes.add! 1
      end
    end
  end
end

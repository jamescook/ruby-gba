# frozen_string_literal: true

require "test_helper"

# A game costs what the player makes it cost. These run real ROMs through the emulator
# and assert the profiler finds the frames a PLAYER meets, not only the one the game
# draws standing still.
#
# This is the raycaster's lesson as an executable test: it read 225 of 228 doing nothing
# and 228 the moment the view turned, so a profiler that only ever looked at a settled
# frame called a game that ran at 32fps "fine". The programs below are the same shape
# boiled down — nearly free at rest, over budget while a button is down.
class TestAnalyzerInput < Minitest::Test

  Analyzer = RubyGBA::Analyzer

  # Enough passes of a trivial body to fill a whole frame — the workload stands in for
  # any per-frame work whose amount follows the player (a raycaster's taller columns, a
  # list of spawned enemies, a screen that fills up).
  #
  # A body this plain lets the loop keep its counter in a register, which is most of twice
  # as fast as one that has to go through memory — so it takes rather more passes to fill a
  # frame than the shape of the number suggests.
  OVER_A_FRAME = 24_000
  # Enough to be plainly visible in a reading but nowhere near the ceiling.
  A_VISIBLE_SLICE = 1500

  def build(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Free unless the player holds LEFT, then far too much to fit a frame.
  def expensive_while_held(passes = OVER_A_FRAME, button: :left)
    build do
      screen :bitmap
      var :x, 0
      game_loop do
        held(button).then { repeat(passes) { add :x, 1 } }
      end
    end
  end

  # --- the headline: input is what the reading was missing ---

  # The whole bug in one assertion. Measured doing nothing, this game costs a fraction of
  # a scanline and every frame lands; measured the way it is played, it drops half its
  # frames. The profiler has to report the second.
  def test_a_game_that_only_costs_while_a_button_is_held_reads_as_over_budget
    program = expensive_while_held
    at_rest = Analyzer.measure_program(program, keys: [])
    refute at_rest.saturated?, "standing still this game is nearly free — that was the trap"

    played = Analyzer.measure_program(expensive_while_held)
    assert played.saturated?, "held down, it cannot finish a frame"
    assert_operator played.fps, :<, 45, "it drops frames while the button is down"
    assert_equal [:left], played.keys, "the reading says which button found it"
  end

  # The verdict names what the player was doing, because the number means nothing without
  # it — "fine" and "fine until someone plays it" read the same otherwise.
  def test_the_worst_reading_carries_the_buttons_that_produced_it
    result = Analyzer.measure_program(expensive_while_held(A_VISIBLE_SLICE, button: :a))
    assert_equal [:a], result.keys
    assert result.held?
  end

  # A game whose cost does not follow the player still reports at rest, with no button
  # named — nothing to warn about, and no invented input.
  #
  # The button here does cost something — one statement — and that is the point: a reading is
  # attributed to a button only when the button is worth blaming, which one statement a frame
  # is not. Without that floor the dearest attempt wins by a thousandth of a scanline, and the
  # report points a reader at a button that is doing nothing.
  def test_a_game_input_does_not_make_dearer_reports_no_buttons
    program = build do
      screen :bitmap
      x = var :x, 0
      game_loop do
        repeat(A_VISIBLE_SLICE) { x.add 1 }
        held(:left).then { x.add 1 }
      end
    end
    result = Analyzer.measure_program(program)
    assert_empty result.keys, "no button cost more than none held"
    refute result.held?
  end

  # --- which buttons get held ---

  # The game says which buttons matter. A profiler that held all ten would spend its time
  # on buttons the program never reads. The last attempt holds every one of them at once —
  # see the two tests below for why that is the only one that finds the worst frame.
  def test_the_buttons_tried_are_the_ones_the_program_reads
    program = build do
      screen :bitmap
      var :x, 0
      game_loop do
        held(:left).then { add :x, 1 }
        pressed(:start).then { add :x, 1 }
      end
    end
    assert_equal [%i[], [:left], [:start], %i[left start]], Analyzer.attempt_keys(program)
  end

  # ...and one button is not worth holding twice. A game reading a single button has
  # nothing to combine, so there is no all-at-once attempt to make.
  def test_a_game_that_reads_one_button_gets_no_combined_attempt
    program = build do
      screen :bitmap
      var :x, 0
      game_loop { held(:left).then { add :x, 1 } }
    end
    assert_equal [[], [:left]], Analyzer.attempt_keys(program)
  end

  # A game that reads no buttons is measured standing still, and only that.
  def test_a_game_that_reads_no_buttons_is_only_measured_at_rest
    program = build do
      screen :bitmap
      game_loop { clear_screen :blue }
    end
    assert_equal [[]], Analyzer.attempt_keys(program)
  end

  # Naming the buttons pins them: the profiler holds exactly those and sweeps nothing.
  def test_named_buttons_are_held_as_asked
    program = expensive_while_held(A_VISIBLE_SLICE)
    pinned = Analyzer.measure_program(program, keys: [:left])
    at_rest = Analyzer.measure_program(program, keys: [])
    assert_equal [:left], pinned.keys
    assert_operator pinned.scanlines, :>, at_rest.scanlines + 5,
                    "holding the button it cares about costs plainly more"
  end

  # --- the worst frame holds every button, not the dearest one ---

  # THE FRAME A SWEEP OF SINGLE BUTTONS CANNOT REACH. Each button here guards work of its
  # own, so a frame with both down does both bodies and costs about twice either one. A
  # profiler holding them one at a time finds half of its own worst frame and calls that the
  # answer — which is also not the frame the estimate prices, since nothing at build time
  # says a player will not hold two directions, so every guarded body is charged.
  def test_the_worst_frame_holds_every_button_the_game_reads
    program = build do
      screen :bitmap
      x = var :x, 0
      game_loop do
        held(:left).then { repeat(A_VISIBLE_SLICE) { x.add 1 } }
        held(:up).then { repeat(A_VISIBLE_SLICE) { x.add 1 } }
      end
    end
    one = Analyzer.measure_program(program, keys: [:left])
    both = Analyzer.measure_program(program)

    assert_equal %i[left up], both.keys, "the worst frame is the one with both down"
    assert_operator both.scanlines, :>, one.scanlines * 1.5,
                    "two bodies cost about twice one: #{both.scanlines} against #{one.scanlines}"
  end

  # A GAME SMALL ENOUGH THAT ITS WHOLE FRAME IS UNDER THE OLD FLOOR. A button that doubles
  # such a frame moves the reading by a hundredth of a scanline, and the floor for blaming it
  # used to be a quarter — so the dearer reading was thrown away and the game was scored
  # standing still. That is what put four tiled examples a fifth under the console.
  def test_a_button_is_found_even_when_the_whole_frame_is_a_fraction_of_a_scanline
    program = build do
      screen :bitmap
      x = var :x, 0
      game_loop { held(:left).then { repeat(20) { x.add 1 } } }
    end
    at_rest = Analyzer.measure_program(program, keys: [])
    found = Analyzer.measure_program(program)

    assert_operator at_rest.scanlines, :<, 1.0, "the whole frame is a fraction of a scanline"
    assert_equal [:left], found.keys, "the button is still what makes the worst frame"
    assert_operator found.scanlines, :>, at_rest.scanlines, "and the reading is the dearer one"
  end

  # --- every frame in the window, not one sample ---

  # An expensive frame that only comes around now and then is still the frame the player
  # meets. Reading one settled frame finds it only by luck, so every frame in the window
  # is read and the worst kept.
  def test_a_frame_that_costs_more_once_in_a_while_is_the_one_reported
    every_tenth = build do
      screen :bitmap
      var :x, 0
      game_loop do
        every(10) { repeat(A_VISIBLE_SLICE) { add :x, 1 } }
      end
    end
    every_frame = build do
      screen :bitmap
      var :x, 0
      game_loop do
        repeat(A_VISIBLE_SLICE) { add :x, 1 }
      end
    end
    occasional = Analyzer.measure_program(every_tenth)
    constant = Analyzer.measure_program(every_frame)
    assert_in_delta constant.scanlines, occasional.scanlines, 5.0,
                    "the expensive frame costs the same however rarely it comes around"
  end

  # --- the frame count is taken the same way the reading was ---

  # The scanline reading saturates at a full frame, so a saturated game is counted
  # instead. That count has to hold the same buttons, or it answers about a game standing
  # still — which was exactly the raycaster reporting 60fps while it ran at 32.
  def test_the_frame_count_holds_the_same_buttons_as_the_reading
    program = expensive_while_held
    counted_at_rest = Analyzer.measure_fps(program, {}, keys: [])
    assert_in_delta 60, counted_at_rest, 6, "doing nothing, every frame lands"

    counted_held = Analyzer.measure_fps(expensive_while_held, {}, keys: [:left])
    assert_operator counted_held, :<, 45, "with the button down, half the frames are dropped"
  end

  # --- a held button must not measure a different scene ---

  # START on a game-over screen starts a new game. Holding it measures the playing scene
  # and would report it under the game-over name, so that attempt is thrown away.
  def test_a_button_that_leaves_the_scene_is_not_reported_for_that_scene
    program = build do
      screen :bitmap
      var :state, 0
      var :x, 0
      scene(:over) do
        pressed(:start).then { set :state, 1 }
      end
      scene(:playing) { repeat(OVER_A_FRAME) { add :x, 1 } }
      game_loop do
        case_var(:state) do
          when_val 0, :over
          when_val 1, :playing
        end
      end
    end
    over = Analyzer.measure_program(program, stays_in: { var: :state, value: 0 })
    refute over.saturated?,
           "the game-over screen is cheap — holding START ran the playing scene, which is not this scene"
    assert_empty over.keys
  end

  # The guard only throws away attempts that LEFT the scene. A button the scene handles
  # itself is measured and reported for it.
  def test_a_button_the_scene_keeps_handling_is_still_measured
    program = build do
      screen :bitmap
      var :state, 0
      var :x, 0
      scene(:playing) do
        held(:left).then { repeat(A_VISIBLE_SLICE) { add :x, 1 } }
      end
      game_loop do
        case_var(:state) do
          when_val 0, :playing
        end
      end
    end
    result = Analyzer.measure_program(program, stays_in: { var: :state, value: 0 })
    assert_equal [:left], result.keys
  end
end

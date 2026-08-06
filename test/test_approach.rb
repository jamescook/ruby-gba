# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The approach motion verb: nudge a variable toward a target by at most a fixed
# step each call, never overshooting — the "chase, capped to a top speed" move
# pong's CPU paddle makes. It's a composite over the value model (a clamped
# delta), so it behaves the same on every backend; these tests assert the value
# it lands on, both in the interpreter and on real hardware.
class TestApproach < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  Color = RubyGBA::Color

  # Build through the DSL and run on the reference backend, returning the
  # interpreter (read a variable's final value with i[:name]).
  def interpret(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    Reference.new.run(builder.program)
  end

  # Build the IR without running it — for the guardrail tests, which must raise
  # as the program is built, before anything runs.
  def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # ---- one step ----

  def test_moves_toward_a_higher_target_by_the_step
    i = interpret do
      x = var :x, 0
      x.approach 100, 10
    end
    assert_equal 10, i[:x]
  end

  def test_moves_toward_a_lower_target_by_the_step
    i = interpret do
      x = var :x, 100
      x.approach 0, 10
    end
    assert_equal 90, i[:x]
  end

  # ---- the whole point of approach: it never overshoots ----

  def test_lands_exactly_on_a_target_within_one_step
    # 3 away, step 10 — a dumb "always move by the step" would jump to 15 and then
    # jitter around the target forever; approach caps the last step so it lands on
    # 8 and stays.
    i = interpret do
      x = var :x, 5
      x.approach 8, 10
    end
    assert_equal 8, i[:x]
  end

  def test_lands_exactly_when_the_target_is_below_and_within_a_step
    i = interpret do
      x = var :x, 5
      x.approach 3, 10
    end
    assert_equal 3, i[:x]
  end

  def test_at_the_target_it_stays_put
    i = interpret do
      x = var :x, 7
      x.approach 7, 10
    end
    assert_equal 7, i[:x]
  end

  # ---- over many frames it converges and settles (no oscillation) ----

  def test_converges_and_settles_over_frames
    i = interpret do
      x = var :x, 0
      f = var :f, 0
      game_loop do
        x.approach 100, 7        # 100 / 7 → 15 steps to arrive
        f.add 1
        (f >= 30).then { halt }  # well past arrival
      end
    end
    assert_equal 100, i[:x]      # landed exactly and never drifted past
  end

  # ---- target can be an expression or another variable ----

  def test_target_may_be_an_expression
    # pong's shape: chase (ball_y - offset). Here ball_y = 50, offset = 10 → 40.
    i = interpret do
      ball_y = var :ball_y, 50
      cpu = var :cpu, 0
      cpu.approach ball_y - 10, 6
    end
    assert_equal 6, i[:cpu]
  end

  def test_target_may_be_another_variable
    i = interpret do
      var :goal, 20
      x = var :x, 0
      x.approach :goal, 5
    end
    assert_equal 5, i[:x]
  end

  # ---- independent call sites keep their own hidden delta ----

  def test_two_approaches_do_not_clobber_each_other
    i = interpret do
      a = var :a, 0
      b = var :b, 100
      a.approach 100, 10
      b.approach 0, 10
    end
    assert_equal 10, i[:a]
    assert_equal 90, i[:b]
  end

  # ---- guardrails ----

  def test_step_must_be_positive
    err = assert_raises(ArgumentError) { tree { var(:x, 0).approach 100, 0 } }
    assert_match(/positive/, err.message)
  end

  def test_step_must_be_a_whole_number
    err = assert_raises(ArgumentError) { tree { var(:x, 0).approach 100, 2.5 } }
    assert_match(/whole number/, err.message)
  end

  def test_approaching_an_expression_is_a_friendly_error
    # Only a variable has somewhere to store the result.
    err = assert_raises(ArgumentError) { tree { (var(:x, 0) + 1).approach 100, 10 } }
    assert_match(/only a variable/, err.message)
  end

  # ---- a step the game works out as it runs ----

  # What a pack needs: how fast to move is decided from an argument (fade_out over
  # 30 frames), so the step cannot be a number written into the program.
  def test_the_step_can_be_a_variable
    i = interpret do
      speed = var :speed, 10
      x = var :x, 0
      3.times { x.approach 100, speed }
    end

    assert_equal 30, i[:x]
  end

  def test_a_step_the_game_changes_changes_how_fast_it_moves
    i = interpret do
      speed = var :speed, 5
      x = var :x, 0
      x.approach 100, speed # +5
      speed.set 20
      x.approach 100, speed # +20
    end

    assert_equal 25, i[:x]
  end

  def test_a_computed_step_still_lands_exactly_on_the_target
    i = interpret do
      speed = var :speed, 30
      x = var :x, 0
      4.times { x.approach 100, speed }
    end

    assert_equal 100, i[:x], "it stops on the target rather than overshooting past it"
  end

  # A step is a distance, so its sign says nothing about direction — the target does
  # that. Read the other way round, a step that went negative mid-game would drive the
  # variable away from its target for ever, silently.
  def test_a_negative_computed_step_still_moves_toward_the_target
    i = interpret do
      speed = var :speed, -10
      x = var :x, 0
      x.approach 100, speed
    end

    assert_equal 10, i[:x]
  end

  def test_a_computed_step_of_zero_holds_still
    i = interpret do
      speed = var :speed, 0
      x = var :x, 50
      x.approach 100, speed
    end

    assert_equal 50, i[:x]
  end

  # ---- a bound the game works out as it runs (what approach is built on) ----

  def test_clamp_takes_a_variable_bound
    i = interpret do
      limit = var :limit, 40
      x = var :x, 100
      x.clamp 0, limit
    end

    assert_equal 40, i[:x]
  end

  def test_a_clamp_bound_can_be_an_expression
    i = interpret do
      width = var :width, 20
      x = var :x, 100
      x.clamp 0, width * 2
    end

    assert_equal 40, i[:x]
  end

  def test_a_variable_bound_that_moves_moves_the_limit
    i = interpret do
      limit = var :limit, 40
      x = var :x, 100
      x.clamp 0, limit
      limit.set 90
      x.set 100
      x.clamp 0, limit
    end

    assert_equal 90, i[:x]
  end

  # ---- both backends agree, on real hardware ----

  # A green marker whose x is the approached value: it starts at 0 and homes in
  # on 100, so where it ends up on screen reveals the number approach computed.
  def marker_program(frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      x = var :x, 0
      f = var :f, 0
      game_loop do
        wait_vblank
        clear_screen :black
        x.approach 100, 7
        draw_rect_at :x, 50, 2, 2, :green
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_interpreter_marker_homes_in
    screen = Reference.new.run(marker_program(frames: 20)).screen
    assert_equal Color.resolve(:green), screen.pixel(100, 50), "marker arrived at the target"
    assert_equal Color.resolve(:black), screen.pixel(0, 50),   "and left the start column"
  end

  def test_marker_homes_in_on_hardware
    machine_code = RubyGBA::IR::Backends::GBA.new.lower(marker_program(frames: 20))
    rom = RubyGBA::ROM.assemble(machine_code, title: "APPROACH", code: "BAPP", maker: "01")

    v = assert_gemba_loads_rom(rom, frames: 22)
    assert v.green?(100, 50), "the marker reached the target on hardware"
    assert v.black?(0, 50),   "and left the start column"
  end

  # The same marker, but the step and the limit are variables, so it runs the lowering
  # that EVALUATES a bound instead of loading a fixed one.
  #
  # Read two moments, and pick them so no single wrong answer can pass both. Early, the
  # marker is mid-journey at a spot that is neither the target nor the limit — only the
  # right step arithmetic puts it there. Later it is pinned against the limit — so a
  # lowering that ignored the bound would sail past. A lowering that dropped the value
  # it was clamping and kept the bound would sit on the limit from the first frame, and
  # fail the early reading.
  def limited_marker_program(frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      x = var :x, 0
      speed = var :speed, 7
      limit = var :limit, 60
      f = var :f, 0
      game_loop do
        wait_vblank
        clear_screen :black
        x.approach 200, speed # a step the game holds in a variable
        x.clamp 0, limit      # and a ceiling it holds in another
        draw_rect_at :x, 50, 2, 2, :green
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # Five steps of 7, well short of both the target (200) and the limit (60).
  MID_JOURNEY = 35

  def test_a_run_time_step_and_bound_land_in_the_right_place
    early = Reference.new.run(limited_marker_program(frames: 5)).screen
    late = Reference.new.run(limited_marker_program(frames: 20)).screen

    assert_equal Color.resolve(:green), early.pixel(MID_JOURNEY, 50),
                 "mid-journey it is where the run-time step put it"
    assert_equal Color.resolve(:black), early.pixel(60, 50), "not already pinned at the limit"
    assert_equal Color.resolve(:green), late.pixel(60, 50), "later it is held at the run-time limit"
  end

  def test_a_run_time_step_and_bound_agree_on_hardware
    early = rom_for(limited_marker_program(frames: 5))
    late = rom_for(limited_marker_program(frames: 20))

    v_early = assert_gemba_loads_rom(early, frames: 7)
    v_late = assert_gemba_loads_rom(late, frames: 22)

    assert v_early.green?(MID_JOURNEY, 50), "the console stepped by the same amount"
    assert v_early.black?(60, 50), "and had not reached the limit yet"
    assert v_late.green?(60, 50), "and it holds at the same limit"
  end

  def rom_for(program)
    RubyGBA::ROM.assemble(RubyGBA::IR::Backends::GBA.new.lower(program),
                          title: "APPROACH", code: "BAPP", maker: "01")
  end
end

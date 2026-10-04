# frozen_string_literal: true

require "test_helper"

# A routine the game declares and nothing ever calls. It is still put in the cartridge, and it
# never runs, so a game that forgot the `call` looks right in the code and does nothing on
# screen. The build says so, naming the routine. Every way a game can reach a routine has to
# count as a call, because a warning about a routine that does run sends the author to delete
# working code.
class TestIRGuardrailRoutineNeverCalled < Minitest::Test
  Guardrails = RubyGBA::IR::Guardrails

  def findings(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    Guardrails::Validator.new(checks: [Guardrails::Checks::RoutineNeverCalled.new])
                         .run(builder.program, autofix: false).findings
  end

  def test_a_routine_nothing_calls_is_named
    found = findings do
      screen :bitmap
      func(:draw_status) { fill_rect 0, 0, 8, 8, :red }
      game_loop { clear_screen :black }
    end

    assert_equal 1, found.size
    assert found.first.warning?, "the cartridge still builds"
    assert_match(/:draw_status/, found.first.message)
    assert_match(/never runs/, found.first.message)
  end

  def test_a_routine_called_only_from_one_nothing_calls_is_named_too
    found = findings do
      screen :bitmap
      func(:outer) { call :inner }
      func(:inner) { fill_rect 0, 0, 8, 8, :red }
      game_loop { clear_screen :black }
    end

    assert_equal %i[inner outer], found.map { |finding| finding.node.name }.sort
  end

  def test_a_scene_nothing_switches_to_is_named_as_a_scene
    found = findings do
      screen :bitmap
      var :state, 0
      scene(:title) { clear_screen :black }
      scene(:credits) { clear_screen :white }
      game_loop { case_var(:state) { when_val 0, :title } }
    end

    assert_equal 1, found.size
    assert_match(/scene :credits/, found.first.message)
  end

  def test_a_routine_called_from_the_game_loop_and_from_another_routine_is_quiet
    assert_empty(findings do
      screen :bitmap
      func(:outer) { call :inner }
      func(:inner) { fill_rect 0, 0, 8, 8, :red }
      game_loop { call :outer }
    end)
  end

  def test_a_routine_called_from_before_the_loop_is_quiet
    assert_empty(findings do
      screen :bitmap
      func(:setup) { clear_screen :black }
      call :setup
      game_loop { wait_vblank }
    end)
  end

  def test_routines_picked_by_number_are_quiet
    assert_empty(findings do
      screen :bitmap
      pick = var :pick, 0
      func(:a) { clear_screen :black }
      func(:b) { clear_screen :white }
      game_loop { call %i[a b], number: pick }
    end)
  end

  def test_routines_named_by_a_variable_are_quiet
    assert_empty(findings do
      screen :bitmap
      mode = var :mode, :idle
      func(:idle) { mode.set! :chase }
      func(:chase) { mode.set! :idle }
      game_loop { call mode }
    end)
  end

  def test_scenes_named_by_a_variable_are_quiet
    assert_empty(findings do
      screen :bitmap
      mode = var :mode, :title
      scene(:title) { mode.set! :playing }
      scene(:playing) { clear_screen :black }
      game_loop { call mode }
    end)
  end

  def test_a_routine_of_a_pool_called_inside_its_walk_is_quiet
    assert_empty(findings do
      screen :bitmap
      guards = pool :guard, x: 0, capacity: 4
      guards.func(:chase) { |g| g.x.add! 1 }
      game_loop { guards.each { |_g| call :chase } }
    end)
  end

  def test_a_routine_called_from_a_timer_handler_is_quiet
    assert_empty(findings do
      screen :bitmap
      var :ticks, 0
      func(:tick) { add! :ticks, 1 }
      timer(:clock, per_second: 60).on_tick { call :tick }
      game_loop { wait_vblank }
    end)
  end

  # The console installs a timer's handler wherever it is written, so a routine the handler
  # calls runs even when the routine around the handler never does.
  def test_a_routine_called_from_a_timer_handler_inside_an_uncalled_routine_is_quiet
    found = findings do
      screen :bitmap
      var :ticks, 0
      func(:tick) { add! :ticks, 1 }
      func(:setup) { timer(:clock, per_second: 60).on_tick { call :tick } }
      game_loop { wait_vblank }
    end

    assert_equal [:setup], found.map { |finding| finding.node.name }
  end

  # A second handler for the same timer replaces the first, so what only the first calls
  # never runs.
  def test_a_routine_called_only_from_a_replaced_handler_is_named
    found = findings do
      screen :bitmap
      var :ticks, 0
      func(:old_tick) { add! :ticks, 1 }
      func(:new_tick) { add! :ticks, 2 }
      clock = timer :clock, per_second: 60
      clock.on_tick { call :old_tick }
      clock.on_tick { call :new_tick }
      game_loop { wait_vblank }
    end

    assert_equal [:old_tick], found.map { |finding| finding.node.name }
  end

  def test_a_routine_called_from_every_and_after_is_quiet
    assert_empty(findings do
      screen :bitmap
      func(:blink) { clear_screen :white }
      func(:start) { clear_screen :black }
      game_loop do
        every(10) { call :blink }
        after(30) { call :start }
      end
    end)
  end

  def test_a_named_once_a_frame_is_quiet
    assert_empty(findings do
      screen :bitmap
      var :clock, 0
      once_a_frame(:keep_time) { add! :clock, 1 }
      game_loop { wait_vblank }
    end)
  end

  def test_a_routine_declared_inside_another_and_called_is_quiet
    assert_empty(findings do
      screen :bitmap
      func(:outer) do
        func(:restart) { clear_screen :black }
        call :restart
      end
      game_loop { call :outer }
    end)
  end
end

# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# A VARIABLE THAT HOLDS A NAME: `var :mode, :title`, `mode.set! :playing`, `call mode`.
#
# A game's states are names, and what keeps them is a variable, which holds a number. Written
# out, the author picks the numbers, keeps a comment saying which is which, and keeps any list
# of routines in that same order. Here the author writes names and the framework numbers them,
# the way it already numbers the colours somebody names.
#
# What is stored is still a number, so this is the same dispatch a number picks — and these
# tests are about the surface over it: that a name means what it says wherever it is written,
# that each instance of a pool keeps its own, and that the set of names is complete even when
# one of them is first used deep inside another routine.
class TestNameVariables < Minitest::Test
  include Differential

  private def program_with(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # --- a name says which routine ---

  def test_the_name_a_variable_holds_says_which_routine_runs
    program = program_with do
      screen :bitmap
      ran = var :ran, 0
      mode = var :mode, :title
      b = self
      b.func(:title) { ran.set! 1 }
      b.func(:playing) { ran.set! 2 }
      game_loop { b.call mode }
    end

    assert_equal 1, game_player.run(program)[:ran], "it starts holding the name it was declared with"
  end

  def test_setting_a_name_changes_which_routine_runs
    program = program_with do
      screen :bitmap
      ran = var :ran, 0
      mode = var :mode, :title
      b = self
      b.func(:title) { ran.set! 1 }
      b.func(:playing) { ran.set! 2 }
      game_loop do
        b.call mode
        mode.set! :playing
      end
    end

    assert_equal 2, game_player.run(program)[:ran]
  end

  # A name reads the same way in a test as it does in an assignment.
  def test_a_name_can_be_compared_against
    program = program_with do
      screen :bitmap
      saw = var :saw, 0
      mode = var :mode, :title
      b = self
      b.func(:title) { b.halt }
      game_loop do
        (mode == :title).then { saw.set! 1 }
        (mode != :title).then { saw.set! 2 }
        b.halt
      end
    end

    assert_equal 1, game_player.run(program)[:saw]
  end

  # THE ORDERING CASE. A state can be reached only from inside another routine — :over is named
  # nowhere but in the body of :playing, and a routine's body is built at the end of the build.
  # So the set of names a variable holds is not complete where the `call` is written, and the
  # list of routines it picks from has to be gathered after everything is built.
  def test_a_name_first_used_inside_a_routine_is_still_one_of_them
    program = program_with do
      screen :bitmap
      ran = var :ran, 0
      mode = var :mode, :title
      b = self
      b.func(:title) { mode.set! :playing }
      b.func(:playing) { mode.set! :over }
      b.func(:over) { ran.set! 99 }
      game_loop { b.call mode }
    end

    assert_equal 99, game_player.run(program)[:ran],
                 "the game walked title -> playing -> over, and :over was reachable"
  end

  # --- one per instance ---

  # THE CASE A POOL WANTS: thirty guards, each in its own state, and one line inside `each`
  # running a different routine for every one of them.
  def test_each_pooled_instance_keeps_its_own_state
    program = program_with do
      screen :bitmap
      idled = var :idled, 0
      chased = var :chased, 0
      guards = pool :guard, x: 0, state: :idle, capacity: 8
      b = self
      b.func(:idle) { idled.add! 1 }
      b.func(:chase) { chased.add! 1 }
      guards.spawn(x: 0)                  # takes the state it was declared with
      guards.spawn(x: 1, state: :chase)   # ...and this one is given another
      guards.spawn(x: 2, state: :chase)
      game_loop do
        guards.each { |g| b.call g.state }
        b.halt
      end
    end
    interpreted = game_player.run(program)

    assert_equal 1, interpreted[:idled]
    assert_equal 2, interpreted[:chased]
  end

  def test_an_instance_can_change_its_own_state
    program = program_with do
      screen :bitmap
      chased = var :chased, 0
      guards = pool :guard, x: 0, state: :idle, capacity: 8
      b = self
      b.func(:idle) { nil }
      b.func(:chase) { chased.add! 1 }
      guards.spawn(x: 0)
      game_loop do
        guards.each do |g|
          (g.state == :idle).then { g.state.set! :chase }
          b.call g.state
        end
      end
    end

    assert_operator game_player.run(program)[:chased], :>, 0
  end

  # --- and the console agrees ---

  def test_both_backends_run_the_routine_the_name_picked
    program = program_with do
      screen :bitmap
      clear_screen :black
      mode = var :mode, :title
      b = self
      b.func(:title) { b.fill_rect 10, 10, 40, 40, :red }
      b.func(:playing) { b.fill_rect 100, 10, 40, 40, :green }
      b.func(:over) { b.fill_rect 190, 10, 40, 40, :blue }
      game_loop do
        b.call mode
        mode.set! :playing
      end
    end

    assert_backends_agree(program, frames: 3)
  end

  # --- what it refuses ---

  def test_a_variable_that_holds_numbers_cannot_name_a_routine
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        count = var :count, 0
        game_loop { call count }
      end
    end

    assert_match(/holds numbers, not names/, err.message)
    assert_match(/number:/, err.message, "and it says what to write instead")
  end

  def test_a_name_with_no_routine_of_its_own_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        mode = var :mode, :title
        b = self
        b.func(:title) { b.halt }
        game_loop do
          b.call mode
          mode.set! :paused          # a state, but nothing to run for it
        end
      end
    end

    assert_match(/:paused is called but never defined/, err.message)
  end

  # --- a name that picks a SCENE ---
  #
  # `call mode` over names that are scenes is the same thing as a `case_var` over them: each
  # scene owns what it declares — its tiled text, its sprites, its scenery — and shows it only
  # while it runs.

  # A name that is both a scene and a routine leaves `call` not knowing which to run.
  def test_a_name_that_is_a_scene_and_a_routine_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        mode = var :mode, :title
        b = self
        b.scene(:title) { b.halt }
        b.func(:title) { b.halt }
        game_loop { b.call mode }
      end
    end

    assert_match(/:title is both a scene and a func/, err.message)
  end

  # A variable whose names are partly scenes and partly funcs would make `call` pick a screen
  # for some values and run a routine for others, so it is refused, naming which are which.
  def test_names_that_mix_scenes_and_routines_are_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        mode = var :mode, :title
        b = self
        b.scene(:title) { mode.set! :tick }
        b.func(:tick) { mode.set! :title }
        game_loop { b.call mode }
      end
    end

    assert_match(/picks a scene\. It also holds funcs \(:tick\)/, err.message)
    refute_match(/_scene_/, err.message)
  end

  # The same mix said where the game loop reads it, before any routine's body is built.
  def test_names_that_mix_scenes_and_routines_are_refused_wherever_the_func_is_named
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        mode = var :mode, :title
        b = self
        b.scene(:title) { b.halt }
        b.func(:tick) { b.halt }
        game_loop do
          pressed(:a).then { mode.set! :tick }
          b.call mode
        end
      end
    end

    assert_match(/picks a scene\. It also holds funcs \(:tick\)/, err.message)
  end

  # The mix the other way round: the variable starts on a func, and a scene's name is set
  # only inside that func's body, so it is first seen after the build looked for scenes.
  def test_a_scene_set_only_inside_a_routine_beside_funcs_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        mode = var :mode, :tick
        b = self
        b.func(:tick) { mode.set! :title }
        b.scene(:title) { b.halt }
        game_loop { b.call mode }
      end
    end

    assert_match(/picks a scene\. It also holds funcs \(:tick\)/, err.message)
    refute_match(/never defined/, err.message)
  end

  # Names that are no routine at all, beside scenes, are named as missing, along with any func.
  def test_names_beside_scenes_that_name_nothing_are_refused_as_missing
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        mode = var :mode, :title
        b = self
        b.scene(:title) { pressed(:a).then { mode.set! :walk }.else { mode.set! :run } }
        b.func(:tick) { mode.set! :title }
        game_loop do
          pressed(:b).then { mode.set! :tick }
          b.call mode
        end
      end
    end

    assert_match(/It also holds funcs \(:tick\)/, err.message)
    assert_match(/:walk, :run, which are not scenes or funcs/, err.message)
    refute_match(/_scene_/, err.message)
  end

  def test_a_value_and_a_number_together_are_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        mode = var :mode, :title
        b = self
        b.func(:title) { b.halt }
        game_loop { b.call mode, number: 0 }
      end
    end

    assert_match(/already says which routine/, err.message)
  end

  # A name is not a number: nothing in the program says which number a name got, and nothing
  # needs to. What this pins is that the two never leak into each other — a game that writes
  # `mode.set! :playing` and one that never mentions a number behave the same whichever order
  # the names happened to be numbered in.
  def test_the_numbering_is_the_framework_s_own_business
    ran_first = game_player.run(states_in_order(%i[title playing over]))[:ran]
    ran_last = game_player.run(states_in_order(%i[over playing title]))[:ran]

    assert_equal 2, ran_first, "whichever order the names were first seen in"
    assert_equal 2, ran_last
  end

  private

  # A game that declares its states in +order+ and then plays :playing, whose routine sets
  # :ran to 2. Which numbers the names got depends on the order; what runs does not.
  def states_in_order(order)
    program_with do
      screen :bitmap
      ran = var :ran, 0
      mode = var :mode, order.first
      b = self
      b.func(:title) { ran.set! 1 }
      b.func(:playing) { ran.set! 2 }
      b.func(:over) { ran.set! 3 }
      order.each { |state| (mode == state).then { ran.add! 0 } } # names them, changes nothing
      game_loop do
        mode.set! :playing
        b.call mode
        b.halt
      end
    end
  end
end

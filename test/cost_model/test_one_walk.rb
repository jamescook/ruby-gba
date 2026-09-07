# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# ONE WALK PER PROGRAM, however many questions are asked about it and by however many models
# (lib/ruby_gba/ir/cost_model/catalogue.rb).
#
# Every public question the model answers starts by walking the whole program and cataloguing
# what it found. The walk is nearly all of what a question costs — the pricing that follows it
# is milliseconds — and it comes back with the same answer every time, because it is derived
# from the program and nothing else.
#
# THAT MATTERS BECAUSE OF WHO ASKS. A backend deciding which routines to keep in the console's
# quick memory asks one question PER ROUTINE, so it walked the whole program once for each of
# them to learn something about one. And a build makes several models besides — the guardrails'
# budget checks make one each — which walked it again for themselves. Measured on a game of
# sixty floors, a whole build walked the program thirty-eight times: thirty-three of its
# fifty-four seconds, for one answer. It is one walk now.
#
# So the walk count IS the behaviour here, and that is what these check. The answers were
# already right and stay right; what must not come back is the repetition.
class TestCostModelWalksOnce < CostModelTest
  Catalogue = RubyGBA::IR::CostModel::Catalogue

  # Count the walks a block does, by watching the one thing that performs one.
  def walks
    counted = 0
    counter = Module.new do
      define_method(:build) do |program|
        counted += 1
        super(program)
      end
    end
    Catalogue.singleton_class.prepend(counter)
    yield
    counted
  end

  def a_game
    program do
      screen :bitmap
      score = var :score, 0
      func(:tally) { score.add 1 }
      func(:paint) { fill_rect 0, 0, 20, 20, :red }
      game_loop do
        call :tally
        call :paint
      end
    end
  end

  # THE ONE THAT WAS COSTING THE TIME: a caller asking about each routine in turn.
  def test_a_question_about_every_routine_walks_the_program_once
    prog = a_game
    model = Cost.new
    names = prog.walk.select { |node| node.kind == :func }.map(&:name)

    assert_equal 2, names.length, "the fixture should have two routines to ask about"

    costs = nil
    counted = walks { costs = names.to_h { |name| [name, model.func_frame_cost(prog, name)] } }

    assert_equal 1, counted, "asking about each routine should not re-walk the program"
    assert_operator costs[:paint], :>, costs[:tally], "and the answers are still the right way round"
  end

  # ...and the same for the different KINDS of question, which is what a build really asks: the
  # guardrails want one thing, the report another, the backend a third.
  def test_different_questions_about_one_program_share_the_walk
    prog = a_game
    model = Cost.new

    counted = walks do
      model.frame_cost(prog)
      model.steady_cost(prog)
      model.steady_tear_cost(prog)
      model.analyze(prog)
      model.func_frame_cost(prog, :paint)
    end

    assert_equal 1, counted, "five questions about one program is one walk"
  end

  # SEVERAL MODELS, ONE WALK — which is what a build really looks like. The guardrails' budget
  # checks build one model each and one of them wants different settings from the others, so
  # they cannot share an instance. They can share the WALK, because a catalogue is derived from
  # the program and from nothing else; what differs between models is the pricing afterwards.
  def test_models_configured_differently_still_share_one_walk
    prog = a_game

    counted = walks do
      Cost.new.frame_cost(prog)
      Cost.new(fast_interrupts: true).frame_cost(prog)
      Cost.new.func_frame_cost(prog, :paint)
    end

    assert_equal 1, counted, "three models asking about one program is one walk"
  end

  # ...and they still get their own answers, which is why they are separate models at all.
  def test_a_shared_walk_does_not_share_the_settings
    prog = a_game
    plain = Cost.new
    fast = Cost.new(fast_interrupts: true)

    walks { [plain.frame_cost(prog), fast.frame_cost(prog)] }

    refute_nil plain.frame_cost(prog)
    refute_nil fast.frame_cost(prog)
  end

  # A DIFFERENT PROGRAM GETS ITS OWN WALK, which is the half that keeps the answers right.
  def test_another_program_is_walked_again
    first = a_game
    second = program do
      screen :bitmap
      fill_rect 0, 0, 8, 8, :blue
      halt
    end
    model = Cost.new

    counted = walks do
      model.frame_cost(first)
      model.frame_cost(second)
      model.frame_cost(first)
    end

    assert_equal 3, counted, "each change of program is a walk, and going back is another"
  end

  # ...and the answers do not bleed between them, which is what that walk is for.
  def test_the_answers_do_not_bleed_between_programs
    busy = a_game
    quiet = program do
      screen :bitmap
      fill_rect 0, 0, 2, 2, :blue
      halt
    end
    model = Cost.new

    first = model.frame_cost(busy)
    model.frame_cost(quiet)
    again = model.frame_cost(busy)

    assert_in_delta first, again, 0.001, "the same program must cost the same after another one"
    assert_operator model.frame_cost(quiet), :<, first
  end
end

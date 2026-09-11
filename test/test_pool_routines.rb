# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# A ROUTINE THAT WORKS ON ONE INSTANCE: `guards.func(:chase) { |g| ... }`.
#
# A pool's behaviour starts inside `each` and moves into routines as a game grows — because a
# block written inline is emitted again at every place it is written, and because a game with
# states wants one routine per state. A routine is built once, wherever it is called from, so
# the one thing its own code cannot say is WHICH instance it is running for. The walk says it.
#
# So these tests are about that thread: the routine reaches the instance it ran for, two walks
# over one pool do not lose each other's place, a pool that declares no routines pays nothing
# for any of it, and calling such a routine from outside a walk is refused rather than quietly
# running on whoever was walked last.
class TestPoolRoutines < Minitest::Test
  include Differential

  def program_with(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # --- the routine reaches its instance ---

  def test_a_routine_reads_and_writes_the_instance_it_ran_for
    program = program_with do
      screen :bitmap
      idler = var :idler, 0
      chaser = var :chaser, 0
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |g| g.x.add 1; idler.set g.x }
      guards.func(:chase) { |g| g.x.add 10; chaser.set g.x }
      guards.spawn(x: 0)
      guards.spawn(x: 100, state: :chase)
      b = self
      game_loop do
        guards.each { |g| b.call g.state }
        b.halt
      end
    end
    interpreted = Reference.new.run(program)

    assert_equal 1, interpreted[:idler], "the idling guard started at 0 and crept by 1"
    assert_equal 110, interpreted[:chaser], "...and the chasing one started at 100 and moved by 10"
  end

  # Every instance verb the block form has, a routine has: this one retires the instance it
  # ran for, which is the pool's own bookkeeping rather than one of its fields.
  def test_a_routine_can_retire_the_instance_it_ran_for
    program = program_with do
      screen :bitmap
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |g| g.remove }
      3.times { |i| guards.spawn(x: i) }
      left = var :left, 99
      b = self
      game_loop do
        guards.each { |g| b.call g.state }
        left.set guards.count
        b.halt
      end
    end

    assert_equal 0, Reference.new.run(program)[:left]
  end

  # TWO WALKS OVER ONE POOL, which is what a pairwise test is. The inner walk moves the pool's
  # place all the way to its last instance; the outer one has to carry on with its own. Without
  # the walk putting the place back as it leaves, every outer guard after the first inner walk
  # would run its routine on the last instance instead of itself.
  def test_a_walk_inside_a_walk_leaves_the_outer_one_where_it_was
    program = program_with do
      screen :bitmap
      seen = var :seen, 0
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |g| seen.add g.x }
      guards.spawn(x: 1)
      guards.spawn(x: 10)
      b = self
      game_loop do
        guards.each do |outer|
          guards.each { |inner| inner.x.add 0 } # a walk that changes nothing but the place
          b.call :idle
        end
        b.halt
      end
    end

    assert_equal 11, Reference.new.run(program)[:seen],
                 "each outer guard ran on itself: 1 + 10, not the last one twice"
  end

  # --- and the console agrees ---

  # Each guard's routine paints a rectangle at its own x, so which instance each call ran for
  # is on the screen. Every pixel of both backends' pictures has to match.
  def test_both_backends_run_the_routine_for_the_same_instances
    program = program_with do
      screen :bitmap
      clear_screen :black
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |g| draw_rect_at g.x, 60, 20, 20, :red }
      guards.spawn(x: 10)
      guards.spawn(x: 90)
      guards.spawn(x: 170)
      b = self
      game_loop { guards.each { |g| b.call :idle } }
    end

    assert_backends_agree(program, frames: 3)
  end

  # --- a pool that declares no routine pays nothing ---

  # The walk writes down which instance it is on only for a pool whose routines read it. A
  # pool drawn inline — which is most of them — is emitted exactly as it was.
  def test_a_pool_with_no_routine_of_its_own_writes_nothing_down
    program = program_with do
      screen :bitmap
      bullets = pool :bullet, x: 0, y: 0, capacity: 16
      bullets.spawn(x: 10, y: 10)
      game_loop { bullets.each { |bullet| bullet.y.add 1 } }
    end
    written = program.walk.select { |node| node.kind == :set }.map(&:var)

    assert_empty written.grep(/current|pool_walk/),
                 "nothing reads which instance the walk is on, so nothing is written down"
  end

  # --- what it refuses ---

  def test_calling_it_outside_a_walk_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        guards = pool :guard, x: 0, capacity: 4
        guards.func(:chase) { |g| g.x.add 1 }
        b = self
        game_loop { b.call :chase } # no walk anywhere: which guard is chasing?
      end
    end

    assert_match(/outside a walk/, err.message)
    assert_match(/each/, err.message, "and it says where to call it from")
  end

  # ...including from a plain routine in between, whose advice is to make that one a routine
  # of the pool as well, since that is what it is.
  def test_calling_it_from_a_routine_that_is_not_the_pool_s_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        guards = pool :guard, x: 0, capacity: 4
        guards.func(:chase) { |g| g.x.add 1 }
        b = self
        b.func(:update) { b.call :chase }
        game_loop { guards.each { |g| b.call :update } }
      end
    end

    assert_match(/outside a walk/, err.message)
  end

  # ...but one of the pool's own routines can call another, which is how a state machine is
  # written: :idle sees the player and hands over to :chase.
  def test_one_routine_of_the_pool_can_call_another
    program = program_with do
      screen :bitmap
      chased = var :chased, 0
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |_g| call :chase }
      guards.func(:chase) { |g| g.x.add 5; chased.set g.x }
      guards.spawn(x: 20)
      b = self
      game_loop do
        guards.each { |g| b.call g.state }
        b.halt
      end
    end

    assert_equal 25, Reference.new.run(program)[:chased], "and it ran on the right guard"
  end

  def test_a_routine_needs_a_block
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        pool(:guard, x: 0, capacity: 4).func(:chase)
      end
    end

    assert_match(/needs a block/, err.message)
  end
end

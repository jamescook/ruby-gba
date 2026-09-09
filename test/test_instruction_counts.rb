# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT EACH NODE OF THE PROGRAM TURNED INTO, counted while the code is emitted
# (lib/ruby_gba/ir/backends/gba/attribution.rb). The estimate reads this instead of
# measuring the same instruction counts a second time, so what is pinned here is the three
# claims it rests on: the counts are exclusive, they are per USE of a shared node, and a
# node whose code does not run the way it is written says so.
class TestInstructionCounts < Minitest::Test
  def counts(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    backend = GBA.new
    backend.lower(b.program)
    [b.program, backend.attribution.emitted]
  end

  # Inside the game loop, since a `var` puts a `set` of its own at boot and that one is not
  # what any of these are about.
  def find(program, kind)
    program.walk.find { |node| node.kind == :loop }.walk.find { |node| node.kind == kind }
  end

  # A `set` from a variable is a load and a store, and the two are charged apart: the read
  # to the operand that does it, the store to the statement. That split is what lets the
  # estimate price a statement and its operands separately without counting either twice.
  def test_a_statement_is_charged_for_its_own_instructions_and_not_its_operands
    program, emitted = counts do
      x = var :x, 3
      y = var :y, 0
      game_loop { y.set x }
    end

    assert_equal 1, emitted[find(program, :set)].instructions
    assert_equal 1, emitted[find(program, :var_ref)].instructions
  end

  # The whole statement still adds up to what the emitted code really is — two instructions
  # for a load and a store, however the two are divided between the nodes.
  def test_the_parts_of_a_statement_add_up_to_what_it_emitted
    program, emitted = counts do
      x = var :x, 3
      y = var :y, 0
      game_loop { y.set(x + 2) }
    end

    statement = find(program, :set)
    whole = statement.walk.sum { |node| emitted[node]&.instructions || 0 }

    assert_equal 6, whole, "a store, an operator, a variable read and a number"
  end

  # THE ONE THAT BITES. A `Value` handle held in a Ruby variable and written into many
  # places is ONE node object in many positions of the tree, lowered at each of them.
  # Totalled, it would be charged its own cost as many times over as it appears, and then
  # charged that at every position — measured on examples/breakout.rb, where one variable
  # read sits in sixty-nine places.
  def test_a_node_the_tree_shares_is_counted_once_per_use
    program, emitted = counts do
      x = var :x, 3
      y = var :y, 0
      game_loop { 8.times { y.add x } }
    end

    read = find(program, :var_ref)
    shared = program.walk.count { |node| node.equal?(read) }

    assert_operator shared, :>, 1, "the tree really does share the read"
    assert_equal shared, emitted[read].times
    assert_in_delta 1.0, emitted[read].each_use, 1e-9, "one use of it is one load"
  end

  # A count is only a price where the code runs the way it is written. A divide by
  # something the game works out jumps into a routine, and the count sees the handful of
  # instructions that set the jump up and none of the routine.
  def test_a_call_into_a_routine_is_not_straight
    program, emitted = counts do
      x = var :x, 300
      d = var :d, 7
      y = var :y, 0
      game_loop { y.set(x / d) }
    end

    refute_predicate emitted[find(program, :binop)], :straight?
  end

  # ...and neither is a comparison, which turns the console's flags into a 1 or a 0 by
  # jumping over one of them.
  def test_a_comparison_is_not_straight
    program, emitted = counts do
      x = var :x, 3
      y = var :y, 0
      game_loop { (x > 3).then { y.set 1 } }
    end

    refute_predicate emitted[find(program, :binop)], :straight?
  end

  # A divide by a number written in the program folds into instructions at build time, so
  # there is nothing to jump to and the count is the whole story.
  def test_a_divide_the_build_settles_is_straight
    program, emitted = counts do
      x = var :x, 300
      y = var :y, 0
      game_loop { y.set(x / 100) }
    end

    assert_predicate emitted[find(program, :binop)], :straight?
  end

  # The cartridge carries it, like every other answer the build worked out — that is what
  # lets `rom.explain` price a frame off the build instead of guessing at it.
  def test_the_cartridge_carries_what_each_node_emitted
    rom = RubyGBA.build("COUNT", code: "BCNT", maker: "01", err: StringIO.new) do
      screen :bitmap
      y = var :y, 0
      game_loop { y.add 1 }
    end

    step = rom.source_program.walk.find { |node| node.kind == :add }

    assert_equal 3, rom.emitted[step].instructions
  end

  # Building twice is not building once and adding it up. The build lowers the program a
  # first time to find out how big each routine comes out, and only the real pass counts.
  def test_a_second_pass_replaces_the_first_rather_than_adding_to_it
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      y = var :y, 0
      game_loop { y.add 1 }
    end
    b.emit_pending_functions
    backend = GBA.new
    backend.lower(b.program)
    once = backend.attribution.emitted[b.program.walk.find { |n| n.kind == :add }].instructions
    backend.lower(b.program)
    twice = backend.attribution.emitted[b.program.walk.find { |n| n.kind == :add }].instructions

    assert_equal once, twice
  end
end

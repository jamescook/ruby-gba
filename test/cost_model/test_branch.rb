# frozen_string_literal: true

require_relative "helper"
require "tmpdir"

# WHAT THE TWO ARMS OF A BRANCH COST A FRAME.
#
# An `if/else` runs one arm or the other. It never runs both, and no frame ever pays for both —
# so a model that adds them together is not being cautious, it is doing arithmetic that cannot
# be right. It used to.
#
# It went unnoticed because it only shows where the arms are expensive and alike, which is
# exactly what a renderer looks like: Wolfenstein draws a wall one way and a door the other,
# every strip of every frame, and was charged for two walls. That doubling landed on the single
# most expensive line in the game.
class TestBranch < Minitest::Test
  include CostArith

  BUSY = 40 # statements per arm, enough to be far above everything else in the program

  # A program with one branch. +arms+ is how many arms have a body; +cond+ picks what is being
  # branched on, which is what decides whether the share is KNOWN.
  def branching(arms: 2, cond: :unknown, then_busy: BUSY, else_busy: BUSY)
    RubyGBA.build("BRAN", code: "ZBRN", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      spin = var :spin, 0
      flag = var :flag, 0
      game_loop do
        test = case cond
               when :chance then chance(50)
               when :pressed then pressed(:a)
               else flag == 1
               end
        branch = test.then { then_busy.times { spin.add 1 } }
        branch.else { else_busy.times { spin.add 1 } } if arms == 2
      end
    end
  end

  def steady(rom) = rom.cost_model.steady_cost(rom.source_program)

  # A branch with nothing in either arm, so a body's cost can be read as a difference.
  def bare = @bare ||= steady(branching(then_busy: 0, else_busy: 0))

  # THE HEART OF IT. Two arms of the same weight cost a frame what ONE of them costs, because
  # one of them is what runs. Added together they came to twice that.
  def test_two_arms_cost_a_frame_what_one_arm_costs
    one_arm = steady(branching(arms: 1))
    two_arms = steady(branching(arms: 2))

    assert_in_delta one_arm - bare, two_arms - bare, (one_arm - bare) * 0.02,
                    "an else arm of the same weight must not double the cost"
  end

  # ...and where they differ, the dearer one is charged. Nothing in a plain comparison says
  # which way it goes, so the honest answer to "one of these runs" is the one that costs more —
  # never less than the console spends.
  def test_the_dearer_arm_is_what_a_frame_is_charged
    heavy_then = steady(branching(then_busy: BUSY, else_busy: 4))
    heavy_else = steady(branching(then_busy: 4, else_busy: BUSY))
    only_heavy = steady(branching(arms: 1, then_busy: BUSY))

    assert_in_delta heavy_then, heavy_else, heavy_then * 0.01,
                    "which arm is the dear one cannot change what the frame is charged"
    assert_in_delta only_heavy - bare, heavy_then - bare, (only_heavy - bare) * 0.02,
                    "and it is the dear arm's cost, not the pair's"
  end

  # WHEN THE SHARE IS KNOWN the two arms are weighted by it instead, because then an average
  # frame really does pay a share of each. A `chance(50)` runs each arm half the time, so two
  # equal arms cost one arm — the same answer by a different route, and it is the route that
  # matters when the arms differ.
  def test_a_known_share_weights_the_arms_rather_than_taking_the_dearer
    lopsided = steady(branching(cond: :chance, then_busy: BUSY, else_busy: 0))
    only_then = steady(branching(cond: :chance, arms: 1, then_busy: BUSY))
    bare_chance = steady(branching(cond: :chance, then_busy: 0, else_busy: 0))

    assert_in_delta (only_then - bare_chance), (lopsided - bare_chance),
                    (only_then - bare_chance) * 0.02,
                    "half of a heavy arm and half of an empty one is half a heavy arm"
    assert_operator lopsided - bare_chance, :<, steady(branching(then_busy: BUSY, else_busy: 0)) - bare,
                    "...which is less than an unknown branch, where the whole arm is charged"
  end

  # A `pressed` edge never counts toward the steady load, so the arm behind it is free and the
  # ELSE arm is what a frame pays — which is the plain reading of "this runs unless you press it".
  def test_an_edge_charges_the_arm_that_runs_when_you_do_not_press
    edged = steady(branching(cond: :pressed, then_busy: BUSY, else_busy: 4))
    empty_then = steady(branching(cond: :pressed, then_busy: 0, else_busy: 4))

    assert_in_delta empty_then, edged, empty_then * 0.02,
                    "the pressed arm is a transition, so it adds nothing to the every-frame load"
  end

  # --- and against the console -------------------------------------------------------

  # A branch whose arms are alike costs a frame one arm, whichever way it goes. Held against the
  # emulator, because this is the number an author decides by.
  #
  # READ AS A DIFFERENCE against the same program with both arms empty, because a frame costs
  # something before any of this runs — the wait, the page flip — and that floor is most of a
  # reading this small.
  def measured(rom)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "b.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      probe.step(12)
      reading = 3.times.map { 15.times.map { RubyGBA::Analyzer.frame_scanlines(probe.frame_cost) }.max }.min
      probe.close
      return reading
    end
  end

  def test_the_console_pays_for_one_arm
    require_gemba_core!
    heavy = branching(arms: 2, then_busy: 400, else_busy: 400)
    empty = branching(arms: 2, then_busy: 0, else_busy: 0)
    console = measured(heavy) - measured(empty)
    estimate = steady(heavy) - steady(empty)

    assert_in_delta 1.0, estimate / console, 0.2,
                    "two arms of four hundred: estimate #{estimate.round(2)}, console #{console.round(2)}"
  end
end

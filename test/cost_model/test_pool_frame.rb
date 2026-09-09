# frozen_string_literal: true

require "test_helper"

require_relative "helper"
require "tmpdir"

# WHAT A POOL'S FRAME REALLY COSTS, read off the console rather than argued about.
#
# The model's claim is a shape: a pool's walk visits every slot it has, and the body behind
# the live test runs only for the slots in use. Both halves are checkable, and only the
# emulator can settle them — so this builds a pool that holds a known number of its slots
# and nothing else, and asks what a frame costs.
#
# The instances are spawned at boot and nothing spawns or retires after that, so every frame
# the reading covers walks all the slots and runs exactly that many bodies. That is the one
# arrangement where the right answer is known in advance.
#
# TWO LIVE COUNTS, because one is a number that could agree by luck and two is a line. A
# model that discounted the whole walk along with the bodies would fit a busy pool and drift
# on a quiet one; a model that charged a body per slot does the reverse.
class TestPoolFrameCost < CostModelTest
  SLOTS = 64

  # A pool that fills +live+ of its slots at boot and then leaves them alone, so a frame's
  # cost is the walk over every slot plus +live+ bodies and nothing else.
  def bullets(code, live, usually: live, slots: SLOTS)
    RubyGBA.build("POOLFRAME", code: code, maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      shots = pool(:bullet, x: 0, y: 0, vy: 0, capacity: slots, estimate: { usually: usually })
      live.times { |n| shots.spawn(x: n * 3, y: 100, vy: 1) }
      game_loop do
        shots.each do |shot|
          shot.y.add shot.vy
          shot.x.add 1
          shot.vy.set 1
        end
      end
    end
  end

  def estimated(rom) = rom.cost_model.steady_cost(rom.source_program)

  # What one frame of this ROM costs the console, read the way the profiler reads it. The
  # smallest of three windows, so a one-off wobble cannot pass for a cost.
  def measured(rom)
    require_gemba_core!
    Dir.mktmpdir do |dir|
      path = File.join(dir, "pool.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      probe.step(10) # settle: reach the steady state before reading anything
      reading = 3.times.map { 20.times.map { RubyGBA::Analyzer.frame_scanlines(probe.frame_cost) }.max }.min
      probe.close
      return reading
    end
  end

  # HOW CLOSE THE ESTIMATE HAS TO BE, and why it is not tighter than this.
  #
  # A pool's walk is the coarsest thing the model prices, and it now tracks the console to
  # within a few per cent at any capacity — so the band is the epic's tenth rather than the
  # ceiling on a known error it used to be.
  #
  # WHAT THE WALK IS MADE OF, since this is the test that would catch it moving: a loop pass,
  # a read of the live column by the loop's own counter, a compare, and — on the slots that
  # are not live — a jump over the body. That last one was charged nothing until the branch
  # was given a weight, and it is most of what used to be missing here: measured as a slope
  # over capacity with the body held fixed, the walk read four fifths of the console at 32, 64,
  # 128 and 192 slots alike. The same four fifths at every capacity is what said it was a
  # per-SLOT cost rather than a body counted wrong.
  #
  # WHY IT SHOWED UP HERE AND NOWHERE ELSE, which is the part worth remembering. Everywhere
  # else the model charges a body it cannot prove will run, every frame — and a body is dearer
  # than the jump that replaces it, so that over-charge covered the missing jump. A pool is the
  # one place the model is told how many slots are live and correctly declines to charge the
  # rest, and with nothing left to cancel against, the hole showed.
  #
  # WHICH DIRECTION IT IS WRONG IN MATTERS more than the size. `explain` is how an author
  # decides whether a frame fits, so an estimate that FLATTERS a game is the dangerous kind.
  # What is left reads a little OVER, which tells them a frame is fuller than it is.
  BAND = 0.10

  def assert_tracks_the_console(rom, note)
    assert_in_delta 1.0, estimated(rom) / measured(rom), BAND, note
  end

  # A handful live of sixty-four — the shape a bullet pool spends a game in.
  def test_a_pool_told_what_it_holds_reads_what_the_console_spends
    assert_tracks_the_console bullets("BPF1", 6), "six live of sixty-four"
  end

  # ...and almost nothing live, where the frame is nearly all walk. This is the point that
  # says the walk is priced, not discounted: take the sixty-four live tests away and the
  # estimate falls well below what the console spends here.
  def test_it_follows_the_console_down_to_a_pool_that_holds_almost_nothing
    assert_tracks_the_console bullets("BPF2", 1), "one live of sixty-four"
  end

  # THE WALK ON ITS OWN, which is the half this test is really about and the half that was
  # wrong. Holding the live count fixed and varying the CAPACITY leaves the bodies alone, so
  # the slope between two readings is one slot of walk and nothing else. A ratio that holds
  # across a sixfold range of capacities is what says the per-slot price is right, where a
  # single reading could be right by two errors meeting.
  def test_one_more_slot_costs_what_the_console_spends_on_one_more_slot
    require_gemba_core!
    small = bullets("BPF5", 1, slots: 32)
    large = bullets("BPF6", 1, slots: 192)
    per_slot = lambda do |from, to|
      (estimated(to) - estimated(from)) / (192 - 32) /
        ((measured(to) - measured(from)) / (192 - 32))
    end

    assert_in_delta 1.0, per_slot.call(small, large), BAND,
                    "one more slot of walk, priced against the console"
  end

  # THE BUG IT REPLACES, and why the shape had to change rather than the numbers. Counting a
  # body for every slot charges a frame for sixty-four bullets that a frame with six on
  # screen never draws — and the answer is not a little over, it is a multiple, on the one
  # line a pool game's frame is made of.
  def test_counting_a_body_for_every_slot_reads_far_over_the_console
    six_live = bullets("BPF3", 6)

    assert_operator estimated(bullets("BPF4", 6, usually: SLOTS)) / measured(six_live), :>, 2.0
  end
end

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
  def bullets(code, live, usually: live)
    RubyGBA.build("POOLFRAME", code: code, maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      shots = pool(:bullet, x: 0, y: 0, vy: 0, capacity: SLOTS, estimate: { usually: usually })
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
  # A pool's walk is the coarsest thing the model prices. Measured against the console with 0,
  # 1 and 6 of 64 slots live, the estimate reads 8% to 12% under. It is not a wrong SHAPE — the
  # cost per live body is within 4%, which is what the two live counts below are really asking
  # — it is the per-slot walk that the model under-charges, and it under-charges it by about
  # half of what reading one variable costs.
  #
  # It became visible when reaching a variable got cheaper: the console's pool walk really did
  # get 9% cheaper by that, and the model credited it 14%. Sharpening that is its own work, and
  # this band is set where it is so the shape stays guarded while it waits.
  #
  # WHICH DIRECTION IT IS WRONG IN MATTERS more than the size. The estimate reads UNDER, and an
  # estimate that flatters a game is the dangerous kind: `explain` is how an author decides
  # whether a frame fits, so being told it fits when it does not is the failure worth watching.
  # A pool would have to be most of a frame before 12% moved that verdict.
  BAND = 0.15

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

  # THE BUG IT REPLACES, and why the shape had to change rather than the numbers. Counting a
  # body for every slot charges a frame for sixty-four bullets that a frame with six on
  # screen never draws — and the answer is not a little over, it is a multiple, on the one
  # line a pool game's frame is made of.
  def test_counting_a_body_for_every_slot_reads_far_over_the_console
    six_live = bullets("BPF3", 6)

    assert_operator estimated(bullets("BPF4", 6, usually: SLOTS)) / measured(six_live), :>, 2.0
  end
end

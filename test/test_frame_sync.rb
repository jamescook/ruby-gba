# frozen_string_literal: true

require "test_helper"

require "stringio"

# Automatic frame timing: `game_loop` means "run this once per frame", and the
# framework puts the frame sync there so the developer never writes one.
#
# Waiting for the screen to refresh is hardware machinery, so it belongs to the
# framework, not to the person writing a game. `frame_sync: :manual` hands the
# sync to anyone who wants to place it themselves.
#
# Everything here is asserted by counting how many times a loop body runs per
# frame, which is what the sync actually controls. The reference interpreter
# advances a frame on a sync and on nothing else, so a loop paced once per frame
# runs its body exactly once per frame, and an unpaced loop spins until the step
# budget cuts it off.
class TestFrameSync < Minitest::Test

  FRAMES = 5

  # Build through the real entry point, so the flag is exercised the way a
  # developer meets it, and hand back both the program and anything the build
  # said to the developer.
  def build(frame_sync: :auto, &block)
    err = StringIO.new
    rom = RubyGBA.build("SYNC", code: "BSYN", maker: "01",
                        out: StringIO.new, err: err, frame_sync: frame_sync, &block)
    [rom.source_program, err.string]
  end

  # How many times the loop body ran over FRAMES frames.
  def passes(program)
    Reference.new.run(program, frames: FRAMES)[:n]
  end

  # The whole point: no `wait_vblank` anywhere, and the loop still runs at exactly
  # one pass per frame.
  def test_a_game_loop_is_paced_once_per_frame_with_no_sync_written
    program, = build do
      screen :bitmap
      var :n, 0
      game_loop { add :n, 1 }
    end

    assert_equal FRAMES, passes(program),
                 "the loop should run once per frame without the developer writing a sync"
  end

  # Writing the sync anyway is harmless: the loop still runs at one pass per frame,
  # not two syncs and half the rate. The build says where the wait went.
  def test_a_hand_written_sync_does_not_double_the_pace
    program, err = build do
      screen :bitmap
      var :n, 0
      game_loop do
        wait_vblank
        add :n, 1
      end
    end

    assert_equal FRAMES, passes(program), "the pace must stay one pass per frame, not half"
    assert_match(/frame_sync/, err, "and the build says the hand-written sync was dropped")
  end

  # The escape hatch: with manual timing the framework injects nothing, so the
  # developer's own sync is what paces the loop.
  def test_manual_timing_leaves_the_developers_sync_in_charge
    program, err = build(frame_sync: :manual) do
      screen :bitmap
      var :n, 0
      game_loop do
        wait_vblank
        add :n, 1
      end
    end

    assert_equal FRAMES, passes(program)
    refute_match(/frame_sync/, err, "manual timing has nothing to say about a sync it asked for")
  end

  # And manual timing really is manual: leave the sync out and nothing paces the
  # loop, so it runs flat out instead of once per frame.
  def test_manual_timing_without_a_sync_runs_unpaced
    program, = build(frame_sync: :manual) do
      screen :bitmap
      var :n, 0
      game_loop { add :n, 1 }
    end

    i = Reference.new.run(program, frames: FRAMES)
    assert i.stopped_at_budget?, "an unpaced loop should spin until the step budget"
    assert_operator i[:n], :>, FRAMES, "and run its body far more than once per frame"
  end

  # Only the game loop is frame-paced. A `repeat` inside it is ordinary work that
  # finishes within the frame — if it were paced too, this would take 20 frames.
  def test_a_repeat_inside_the_loop_is_not_frame_paced
    program, = build do
      screen :bitmap
      var :n, 0
      game_loop { repeat(4) { add :n, 1 } }
    end

    assert_equal FRAMES * 4, passes(program),
                 "repeat runs to completion inside one frame, it is not paced"
  end

  # A program with no game loop is not being paced by the framework, so a sync the
  # developer wrote is theirs and must survive. Here it presents the drawn page: on
  # the tear-free screen, drop that sync and the picture is never shown.
  def test_a_sync_outside_a_game_loop_is_left_alone
    program, err = build do
      screen :bitmap, tear_free: true
      fill_rect 100, 70, 40, 20, :red
      wait_vblank
      halt
    end

    assert_equal RubyGBA::Color.resolve(:red), Reference.new.run(program).screen.pixel(110, 75),
                 "the developer's own sync presented the page"
    refute_match(/frame_sync/, err, "nothing was dropped, so there is nothing to report")
  end

  # The missing-sync guardrail has nothing to catch here: the framework paced the
  # loop, so no loop is ever missing its sync. It must stay quiet.
  def test_the_missing_sync_warning_does_not_fire
    _program, err = build do
      screen :bitmap
      var :n, 0
      game_loop { add :n, 1 }
    end

    refute_match(/thousands of times a second/, err,
                 "the framework paced the loop, so there is nothing to warn about")
  end
end

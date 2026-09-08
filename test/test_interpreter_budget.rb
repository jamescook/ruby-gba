# frozen_string_literal: true

require "test_helper"

# The reference interpreter carries a step budget so an accidental endless loop can't hang a
# test forever. What that budget COUNTS depends on how the run was asked for, and the two must
# not be confused:
#
#   run(program, frames: 300)   the frames are the stop condition. The budget counts ONE frame,
#                               so every frame asked for is played however much work it takes,
#                               and spending the whole budget inside one frame means that frame
#                               never ends — which raises rather than handing back a part-played
#                               run that looks finished.
#   run(program, max_steps: N)  the budget is the whole run's, and it stops the run wherever it
#                               has got to — at the next frame boundary if the program has
#                               frames, so the screen read afterwards is settled and never torn.
class TestInterpreterBudget < Minitest::Test
  Build = RubyGBA::IR::Build

  # A game loop that fills red, does a chunk of per-frame work, then draws a marker LAST.
  # The screen ends every frame showing the marker; a mid-frame cutoff would show red.
  def marker_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop do
        wait_vblank
        clear_screen :red
        repeat(400) { |_k| pixel 120, 80, :blue } # bulk work, so a cutoff lands inside a frame
        fill_rect 0, 0, 8, 8, :green               # the "frame complete" marker, drawn last
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_budget_cutoff_stops_at_a_frame_boundary_not_mid_frame
    i = Reference.new.run(marker_program, max_steps: 1000) # endless loop -> runs to the step budget
    assert_equal Color.resolve(:green), i.screen.pixel(2, 2),
                 "the cutoff should finish the in-flight frame (marker drawn), not tear it mid-draw"
  end

  def test_it_still_reports_that_the_budget_was_reached
    i = Reference.new.run(marker_program, max_steps: 1000)
    assert i.stopped_at_budget?, "an endless loop still hits the budget; it just stops cleanly"
  end

  # A program with no frames (no wait_vblank) can't 'finish a frame', so it stops at the
  # budget as before — and never runs away.
  def test_a_frameless_loop_stops_at_the_budget
    i = Reference.new.run(Build.program(Build.loop_(Build.add(:x, 1))), max_steps: 100)
    assert i.stopped_at_budget?
    assert_operator i[:x], :<=, 150, "a frame-less loop stops near the budget, not at a runaway multiple"
  end

  # ---------------------------------------------------------------- frames: is the stop condition

  # A frame that draws costs steps — six hundred passes of a counted loop here, about 1,200
  # steps, which is the size of a frame that draws a whole view in a real game. Counted against
  # the whole RUN, the million-step default is spent a few hundred frames in, and every frame
  # after that is silently not played: the run comes back looking finished, with the world
  # frozen where it stopped. This asks for twice as many frames as that budget could ever
  # cover, and :n reaches the number asked for only if every one of them really ran.
  A_LOT_OF_FRAMES = 1_700

  def counting_program(passes: 600)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :n, 0
      game_loop do
        wait_vblank
        repeat(passes) { |_k| pixel 0, 0, :blue }
        add :n, 1
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_run_plays_every_frame_it_asked_for_however_heavy_each_one_is
    i = Reference.new.run(counting_program, frames: A_LOT_OF_FRAMES)

    assert_equal A_LOT_OF_FRAMES, i[:n],
                 "every frame asked for should have run; a shorter count means the budget " \
                 "stopped the run and said nothing"
    refute_predicate i, :stopped_at_budget?, "and it stopped because it had played that far, not at a budget"
  end

  # Said in the small, with a budget the test picks: a frame of this program costs more than
  # 2,000 steps' worth of run over 40 frames, so a whole-run budget would stop it in the first
  # few. Per frame, 2,000 is room to spare and all 40 are played.
  def test_the_budget_counts_one_frame_when_a_run_counts_frames
    i = Reference.new.run(counting_program(passes: 200), frames: 40, max_steps: 2_000)

    assert_equal 40, i[:n], "the budget guards a frame, so it can't cut the run short"
  end

  # And the runaway is still caught — in the frame it happens in, which is better than at some
  # point later, and the message says which frame that was.
  def stuck_program
    Build.program(
      Build.screen(:bitmap),
      Build.loop_(
        Build.wait_vblank,
        Build.add(:n, 1),
        Build.if_(Build.binop(:>=, Build.var_ref(:n), Build.int(4)),
                  Build.loop_(Build.add(:spin, 1)))
      )
    )
  end

  def test_a_frame_that_never_ends_stops_the_run_and_names_it
    err = assert_raises(Reference::ProgramError) do
      Reference.new.run(stuck_program, frames: 20, max_steps: 5_000)
    end

    assert_match(/frame 4/, err.message, "the message should name the frame that never ended")
    assert_match(/never ended/, err.message)
  end

  # THE EXCEPTION, and it's a real program rather than a corner: an unpaced loop
  # (frame_sync: :manual with no wait in it) never reaches a first frame at all. There are no
  # frames for `frames:` to count, so the budget is its only stop and it says so — the same
  # answer a run given max_steps alone gets.
  def test_a_loop_that_never_reaches_a_frame_stops_at_the_budget_rather_than_raising
    i = Reference.new.run(Build.program(Build.screen(:bitmap), Build.loop_(Build.add(:x, 1))),
                          frames: 5, max_steps: 500)

    assert_predicate i, :stopped_at_budget?, "no frames to count, so the budget stopped it"
    assert_operator i[:x], :>, 5, "and it ran flat out rather than once per frame"
  end
end

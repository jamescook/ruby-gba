# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The pong ball/paddle/scoring core — the focused integration test for the
# collision fix. It isn't the whole game (that's examples/pong.rb); it's the part
# that decides whether a ball bounces off a paddle or slips past it to score,
# written in the DSL a person would actually use.
#
# The bug it guards against: a paddle collision that checks only the ball's x
# position acts like a full-height wall, so the ball can never get past to an
# edge and no one can ever score. The fix bounces only when the ball also
# overlaps the paddle's vertical span. These tests drive the ball straight at a
# paddle that is either lined up with it (bounce) or out of the way (score), and
# read the scores back from the interpreter oracle.
class TestPongScoring < Minitest::Test
  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby

  # The example's field/paddle geometry (examples/pong.rb).
  SCREEN_W  = 240
  PADDLE_W  = 4
  PADDLE_H  = 24
  BALL_SIZE = 4
  LEFT_X    = 8
  RIGHT_X   = 228

  # Send a ball horizontally across the field with the paddles parked at fixed
  # heights, and run until someone scores or +frames+ pass. Vertical motion is
  # left out on purpose: the ball holds its row so the test isolates the paddle's
  # vertical-overlap gate — the exact thing the bug got wrong. Returns the
  # finished interpreter run (read scores with r[:player_score] / r[:cpu_score]).
  def run_rally(ball_x:, ball_dx:, ball_row:, player_paddle_y:, cpu_paddle_y:, frames:)
    builder = Builder.new
    builder.instance_eval do
      display :bitmap
      bx     = var :ball_x, ball_x
      by     = var :ball_y, ball_row
      bdx    = var :ball_dx, ball_dx
      ppad   = var :player_y, player_paddle_y
      cpad   = var :cpu_y, cpu_paddle_y
      pscore = var :player_score, 0
      cscore = var :cpu_score, 0
      fc     = var :frame, 0

      game_loop do
        bx.add bdx

        # The fix, verbatim from the example: bounce only when the ball overlaps
        # the paddle's x-band AND its vertical span.
        hits_player = (bx >= LEFT_X) & (bx <= LEFT_X + PADDLE_W) &
                      (by >= ppad - BALL_SIZE) & (by <= ppad + PADDLE_H)
        hits_player.then { bdx.abs }

        hits_cpu = (bx >= RIGHT_X - BALL_SIZE) & (bx <= RIGHT_X + PADDLE_W) &
                   (by >= cpad - BALL_SIZE) & (by <= cpad + PADDLE_H)
        hits_cpu.then { bdx.negate_abs }

        # Off an edge: score and stop, so the count is exactly what happened.
        (bx <= 0).then { cscore.add 1; halt }
        (bx >= SCREEN_W).then { pscore.add 1; halt }

        fc.add 1
        (fc >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    Ruby.new.run(builder.program)
  end

  def test_ball_past_a_mispositioned_player_paddle_scores_for_the_cpu
    # The player's paddle is up at the top (spans y 0..24) while the ball crosses
    # at row 100 — a clean miss. It must reach the left edge and score.
    r = run_rally(ball_x: 40, ball_dx: -2, ball_row: 100,
                  player_paddle_y: 0, cpu_paddle_y: 0, frames: 60)
    assert_equal 1, r[:cpu_score], "a ball that misses the paddle vertically scores"
    assert_equal 0, r[:player_score]
  end

  def test_ball_into_a_lined_up_player_paddle_bounces_instead_of_scoring
    # Now the paddle sits at y=90 (spans 86..114), overlapping the ball at row
    # 100. The ball reaches the x-band, bounces, and never reaches the left edge.
    r = run_rally(ball_x: 40, ball_dx: -2, ball_row: 100,
                  player_paddle_y: 90, cpu_paddle_y: 0, frames: 30)
    assert_equal 0, r[:cpu_score], "a lined-up paddle stops the ball"
    assert_equal 2, r[:ball_dx],   "and sends it back to the right"
  end

  def test_ball_past_a_mispositioned_cpu_paddle_scores_for_the_player
    # Symmetric case on the right edge: the CPU paddle is out of the way, so the
    # ball crossing at row 100 slips past and the player scores.
    r = run_rally(ball_x: 200, ball_dx: 2, ball_row: 100,
                  player_paddle_y: 0, cpu_paddle_y: 0, frames: 60)
    assert_equal 1, r[:player_score], "a ball past the CPU paddle scores for the player"
    assert_equal 0, r[:cpu_score]
  end

  def test_ball_into_a_lined_up_cpu_paddle_bounces_instead_of_scoring
    r = run_rally(ball_x: 200, ball_dx: 2, ball_row: 100,
                  player_paddle_y: 0, cpu_paddle_y: 90, frames: 30)
    assert_equal 0, r[:player_score], "a lined-up CPU paddle stops the ball"
    assert_equal(-2, r[:ball_dx],     "and sends it back to the left")
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/breakout"

# The Breakout example (examples/breakout.rb): the second bitmap-engine POC. It
# exercises the collision verb (overlaps?) against a whole grid of bricks, plus
# lives, score, angle-on-paddle-hit, and win/lose states — the same DSL a person
# would actually write.
#
# We assert at two altitudes: the reference interpreter for the game's *behaviour*
# (a brick actually breaks, the paddle actually steers), which is robust no matter
# where the headless run is cut off; and gemba for the *picture* (the title, the
# brick wall, and the paddle really render), read from settled frames on hardware.
class TestBreakoutExample < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  NUM_BRICKS = Breakout::BRICKS.length

  # Drive input frame by frame: START on frame 1 to leave the title, then whatever
  # `then_hold` says for the rest (a Breakout game auto-plays — the ball moves on
  # its own — so this is enough to exercise real gameplay). 120 frames is a
  # comfortable margin: the ball breaks its first brick and a held paddle clamps at
  # the wall well before frame 40, so the asserted state has settled by here.
  def play(then_hold: [], frames: 120)
    script = lambda do |frame|
      frame == 1 ? [:start] : then_hold
    end
    Ruby.new.input_each_frame(&script).run(Breakout.program, frames: frames)
  end

  # RubyGBA.build runs the guardrails and Doctor, so a clean, non-empty build is
  # itself the structural check.
  def test_the_example_builds_clean
    rom = Breakout.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # The headline behaviour: the ball, serving up into the wall on its own, breaks
  # at least one brick — the brick's flag clears, the wall count drops, and points
  # are scored. This is overlaps? working across the whole grid, in the real game.
  def test_playing_the_ball_breaks_bricks_and_scores
    r = play
    assert_operator r[:bricks_left], :<, NUM_BRICKS, "at least one brick should be gone"
    assert_operator r[:score], :>, 0, "breaking a brick should score points"
  end

  # A destroyed brick stays destroyed: some specific brick's on/off flag reads 0
  # after play (not just the aggregate counter), so the wall really is being torn
  # down brick by brick.
  def test_a_specific_brick_flag_is_cleared
    r = play
    cleared = Breakout::BRICKS.count { |b| r[b[:name]].zero? }
    assert_operator cleared, :>, 0, "at least one brick flag should be cleared"
    assert_equal NUM_BRICKS - cleared, r[:bricks_left],
                 "the wall counter should match the number of standing bricks"
  end

  # Holding RIGHT steers the paddle: after playing with right held, the paddle has
  # travelled to (and clamped at) the right edge. Proves input drives the paddle in
  # the real game, not just in isolation.
  def test_holding_right_drives_the_paddle_to_the_edge
    r = play(then_hold: [:right])
    assert_equal Breakout::SCREEN_W - Breakout::PADDLE_W, r[:paddle_x],
                 "held right, the paddle should end clamped at the right wall"
  end

  # --- Hardware (gemba): the picture really renders ---

  # The title shows "BREAKOUT" in cyan — the simplest proof it isn't a black screen
  # and that text renders through the buffered (indexed) screen.
  def test_the_title_renders_on_the_console
    v = assert_gemba_loads_rom(Breakout.build_rom(err: StringIO.new), frames: 4)
    title_cyan = (50..57).any? { |y| (92..140).any? { |x| v.pixel_is?(x, y, :cyan) } }
    assert title_cyan, "the BREAKOUT title should render cyan in buffered mode"
  end

  # Pressing START enters play, where the wall and paddle are painted every frame.
  # A few frames in, the ball is still climbing toward the wall, so every brick is
  # up: the red top row and the white paddle must both render.
  def test_the_wall_and_paddle_render_on_the_console
    v = assert_gemba_loads_rom(Breakout.build_rom(err: StringIO.new), frames: 8, keys: KEY_START)

    top_row_red = (18..27).any? { |y| (0..238).any? { |x| v.red?(x, y) } }
    assert top_row_red, "the red top row of bricks should render"

    paddle_white = (150..155).any? { |y| (104..136).any? { |x| v.white?(x, y) } }
    assert paddle_white, "the white paddle should render near the bottom"
  end
end

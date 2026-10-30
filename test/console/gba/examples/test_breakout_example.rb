# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/breakout").to_s

# The Breakout example (examples/breakout.rb): the second bitmap-engine POC. It
# exercises the collision verb (overlaps?) against a whole grid of bricks, plus
# lives, score, angle-on-paddle-hit, and win/lose states — the same DSL a person
# would actually write.
#
# The game is made for the Game Boy Advance and the Game Boy Color, so this file is played
# by the runs of each: it is here for the Advance's and, the same, in
# test/console/gbc/examples/ for the Color's. It asserts the game's *behaviour* (a brick
# actually breaks, the paddle actually steers), which is robust no matter where the
# headless run is cut off. The *picture* on the Advance's cartridge (the title, the brick
# wall, and the paddle really render) is read from settled frames in the emulator in
# test/lowering/gba/examples/test_breakout_example_cartridge.rb.
class TestBreakoutExample < Minitest::Test
  NUM_BRICKS = Breakout::BRICKS.length

  # Drive input frame by frame: START on frame 1 to leave the title, then whatever
  # `then_hold` says for the rest (a Breakout game auto-plays — the ball moves on
  # its own — so this is enough to exercise real gameplay). 120 frames is a
  # comfortable margin: the ball breaks its first brick and a held paddle clamps at
  # the wall well before frame 40, so the asserted state has settled by here.
  private def play(then_hold: [], frames: 120)
    script = lambda do |frame|
      frame == 1 ? [:start] : then_hold
    end
    game_player.input_each_frame(&script).run(Breakout::GAME.program(console: game_console), frames: frames)
  end

  # How wide the screen of this run's console is, which the game lays its wall and paddle out on.
  private def screen_width = VBlank::Console.described(game_console).screen_width

  # VBlank.build runs the guardrails and Doctor, so a clean, non-empty build is
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
    assert_equal screen_width - Breakout::PADDLE_W, r[:paddle_x],
                 "held right, the paddle should end clamped at the right wall"
  end
end

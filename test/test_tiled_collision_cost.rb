# frozen_string_literal: true

require "test_helper"
require "differential"

# WHAT TILE COLLISION COSTS, which is a fact about the emitted code rather than about
# the picture — so it is asserted here and the behaviour is asserted in
# test_tiled_collision.rb.
#
# The two things that must stay true: what a mover costs does not depend on what the
# room is made of, and a game with several movers still fits its frame in the console's
# quick memory. Both used to be false. A mover was tested against every rectangle the
# solid cells merged into, written out afresh at each place it moved — so a room with a
# hundred pillars cost twenty-five times a bare one, and eight movers put the game loop
# past 32K, which drops the WHOLE frame to cartridge speed rather than just the moving.
class TestTiledCollisionCost < Minitest::Test
  include Differential

  COLS = 30
  ROWS = 20

  # A bordered room with +pillars+ single solid cells scattered inside it, so the number
  # of solid rectangles can be varied without changing anything else about the game.
  def room_map(pillars)
    r = Random.new(1)
    spots = Array.new(pillars) { [r.rand(2...(COLS - 2)), r.rand(2...(ROWS - 2))] }.to_set
    (0...ROWS).map do |row|
      (0...COLS).map do |col|
        edge = row.zero? || col.zero? || row == ROWS - 1 || col == COLS - 1
        edge || spots.include?([col, row]) ? "#" : "."
      end.join
    end
  end

  def game(movers:, pillars:)
    map = room_map(pillars)
    RubyGBA.build("COLL", code: "BCOL", maker: "01", validate: false,
                  out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image :brick, width: 8, height: 8, data: Array.new(64, RubyGBA::Color.rgb(20, 10, 5))
      image :floor, width: 8, height: 8, data: Array.new(64, RubyGBA::Color.rgb(5, 5, 10))
      tiles :dungeon, "#" => :brick, "." => :floor, solid: ["#"]
      room = background :room, tiles: :dungeon, map: map
      made = (1..movers).map do |i|
        image :"guy#{i}", width: 16, height: 16, data: Array.new(256, RubyGBA::Color.rgb(31, 31, 0))
        sprite(:"guy#{i}", at: [(i * 16) + 8, 24]).blocked_by(room)
      end
      game_loop { made.each { |s| s.move(:right, by: 1); s.move(:down, by: 1) } }
    end
  end

  def loop_bytes(rom) = rom.built.placement.sizes[RubyGBA::BuildRecord::FRAME_ROUTINE].to_i

  # THE ONE THAT MATTERS. A bare room and a room full of pillars are the same code. The
  # grid is consulted, so what the room is MADE of never reaches the mover.
  def test_what_a_mover_costs_does_not_depend_on_the_room
    bare = loop_bytes(game(movers: 4, pillars: 0))
    busy = loop_bytes(game(movers: 4, pillars: 250))

    assert_equal bare, busy,
                 "a bordered room and a maze of pillars must emit the same per-mover code"
  end

  # ...and eight movers fit, which they did not when each wrote the check out twice.
  def test_eight_movers_leave_the_frame_in_the_quick_memory
    rom = game(movers: 8, pillars: 100)

    assert rom.built.fast_frame?, "the frame's own body must stay in the quick memory"
    assert_operator loop_bytes(rom), :<, 8 * 1024,
                    "eight movers should cost a few kilobytes, not tens of them"
  end

  # The check is emitted ONCE for a given background and box size, however many movers
  # consult it — which is what stops the count of movers multiplying the room's cost.
  # Eight movers cost more than one (each still calls it twice), but nothing like eight
  # times the whole check.
  def test_the_check_itself_is_emitted_once
    one = loop_bytes(game(movers: 1, pillars: 100))
    eight = loop_bytes(game(movers: 8, pillars: 100))

    assert_operator eight, :<, one * 8,
                    "the shared routine is not re-emitted per mover (#{one} -> #{eight} bytes)"
  end

  # A POOL CAN HAVE IT TOO, which is the case that most needs it: a game with many movers
  # is exactly the one that could not afford tile collision before. The pool is told once
  # and every instance is checked, sharing the one routine a hand-declared sprite uses.
  def pooled_game(movers)
    map = room_map(60)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :brick, width: 8, height: 8, data: Array.new(64, RubyGBA::Color.rgb(20, 10, 5))
      image :floor, width: 8, height: 8, data: Array.new(64, RubyGBA::Color.rgb(5, 5, 10))
      image :guy, width: 8, height: 8, data: Array.new(64, RubyGBA::Color.rgb(31, 31, 0))
      tiles :dungeon, "#" => :brick, "." => :floor, solid: ["#"]
      room = background :room, tiles: :dungeon, map: map
      guards = pool :guard, x: 0, y: 0, capacity: 32, image: :guy
      guards.blocked_by room
      # Top-level code runs once, at power-on, so this is the cast the room starts with.
      movers.times { |i| guards.spawn(x: (i * 20) + 16, y: 32) }
      game_loop { guards.each { |g| g.move(:right, by: 2); g.move(:down, by: 1) } }
    end
    builder.emit_pending_functions
    builder.program
  end

  # Run until every guard has walked into the far wall and stopped. AT REST is what is
  # compared, on purpose: a moving pool is a frame out of step between the two backends
  # for reasons that have nothing to do with collision (a pool moving with no collision
  # at all disagrees the same way — filed separately), and stopped guards cannot be a
  # frame out. What this pins is the thing collision decides: WHERE they stop.
  def test_a_pool_blocked_by_a_background_stops_in_the_same_place_on_both_backends
    assert_backends_agree(pooled_game(6), frames: 200)
  end

  # A pooled instance stops at a solid tile rather than walking through it — the same
  # behaviour a sprite gets, asserted through the picture.
  def test_a_pooled_instance_stops_at_a_solid_tile
    i = Reference.new.run(pooled_game(1), frames: 40)
    yellow = RubyGBA::Color.rgb(31, 31, 0)
    seen = (0...240).select { |x| (0...160).any? { |y| i.screen.pixel(x, y) == yellow } }

    refute_empty seen, "the guard should be on screen somewhere"
    assert_operator seen.max, :<, COLS * 8, "and inside the room, not through its far wall"
  end

  # And the picture is the same on both backends with several movers in a complex room —
  # the case that never fit before, so it was never run on hardware at all.
  def test_several_movers_in_a_busy_room_agree_on_both_backends
    map = room_map(60)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :brick, width: 8, height: 8, data: Array.new(64, RubyGBA::Color.rgb(20, 10, 5))
      image :floor, width: 8, height: 8, data: Array.new(64, RubyGBA::Color.rgb(5, 5, 10))
      tiles :dungeon, "#" => :brick, "." => :floor, solid: ["#"]
      room = background :room, tiles: :dungeon, map: map
      made = (1..4).map do |i|
        image :"guy#{i}", width: 8, height: 8, data: Array.new(64, RubyGBA::Color.rgb(31, 31, 0))
        sprite(:"guy#{i}", at: [(i * 24) + 16, 32]).blocked_by(room)
      end
      game_loop { made.each { |s| s.move(:right, by: 2); s.move(:down, by: 1) } }
    end
    builder.emit_pending_functions

    assert_backends_agree(builder.program, frames: 20)
  end
end

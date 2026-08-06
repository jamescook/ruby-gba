# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Tiled collision: a tileset marks tiles `solid:`, and a sprite told it's `blocked_by`
# that background stops at those tiles instead of walking through them. The check is
# pure DSL codegen (box overlaps + a guarded move), so both backends run the same IR
# and agree by construction — asserted here on the interpreter oracle and on hardware.
# `can_move?` exposes the same test for manual control.
class TestTiledCollision < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")

  # A 10x5-tile room, floor everywhere but one wall tile at cell (4, 2) -> px (32, 16).
  # A red 8x8 hero starts at +hero_at+; +body+ is the per-frame game-loop code.
  def scene(hero_at:, &body)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall_t,  "#" => :blue) { SOLID8 }
      image(:floor_t, "#" => rgb(8, 8, 8)) { SOLID8 }
      image(:hero_t,  "#" => :red) { SOLID8 }
      tiles :dungeon, "#" => :wall_t, "." => :floor_t, solid: ["#"]
      wall_map = Array.new(5) { |r| (0...10).map { |c| r == 2 && c == 4 ? "#" : "." }.join }
      room = background :room, tiles: :dungeon, map: wall_map
      hero = sprite :hero_t, at: hero_at
      hero.blocked_by room
      instance_exec(hero, &body)
    end
    builder.emit_pending_functions
    builder.program
  end

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "COLLIDE", code: "BCOL", maker: "01")
  end

  # The hero starts at px (16,16) with a wall at px (32,16); holding right, it walks up
  # to the wall and stops flush (its right edge at x32), never entering the wall cell.
  def walk_into_wall
    scene(hero_at: [16, 16]) do |hero|
      game_loop do
        wait_vblank
        held(:right).then { hero.move :right, by: 2 }
      end
    end
  end

  def test_blocked_by_stops_the_sprite_at_a_wall
    s = Reference.new.input_each_frame { [:right] }.run(walk_into_wall, max_steps: 3_000).screen
    assert_equal Color.resolve(:red),  s.pixel(28, 20), "the hero rests flush against the wall (its body at x24..31)"
    assert_equal Color.resolve(:blue), s.pixel(36, 20), "the wall is right there at x32.."
    refute_equal Color.resolve(:red),  s.pixel(36, 20), "the hero never entered the wall cell"
  end

  def test_blocked_by_stops_the_sprite_on_the_console
    v = assert_gemba_loads_rom(rom_for(walk_into_wall), frames: 30, keys: KEY_RIGHT)
    assert v.red?(28, 20),  "the hero stops flush against the wall, got 0x#{format('%04X', v.pixel_gba(28, 20))}"
    assert v.blue?(36, 20), "the wall is at x32, got 0x#{format('%04X', v.pixel_gba(36, 20))}"
    refute v.red?(36, 20),  "the hero never crossed into the wall"
  end

  # can_move? reports the same test for manual control: at the wall it can't step right,
  # but it can still step left (open floor).
  def test_can_move_reports_whether_a_wall_blocks_the_way
    prog = scene(hero_at: [24, 16]) do |hero| # already flush against the wall at x32
      var :went_right, 0
      var :went_left, 0
      game_loop do
        wait_vblank
        hero.can_move?(:right, by: 2).then { set :went_right, 1 }
        hero.can_move?(:left, by: 2).then { set :went_left, 1 }
        halt
      end
    end
    i = Reference.new.run(prog)
    assert_equal 0, i[:went_right], "can_move?(:right) is false — a wall is directly ahead"
    assert_equal 1, i[:went_left],  "can_move?(:left) is true — that way is open floor"
  end

  # Pressed against the wall on its right, moving down-AND-right, the hero still slides
  # down along it: each axis is checked on its own, so the blocked right step doesn't
  # freeze the free down step. (A single combined check would jam it in place.)
  def test_the_sprite_slides_along_a_wall
    prog = scene(hero_at: [24, 16]) do |hero| # flush against the wall, which spans y16..23
      game_loop do
        wait_vblank
        hero.move 2, 2       # down-right, into the wall to its right
        after(3) { halt }    # after 3 steps the down component has carried it to y22
      end
    end
    s = Reference.new.run(prog, max_steps: 3_000).screen
    assert_equal Color.resolve(:red), s.pixel(28, 26),
                 "the right step is blocked by the wall, but the down step still slid the hero down"
  end
end

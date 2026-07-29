# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# Sprite screen-edge helpers: where-is-it-relative-to-the-screen tests read from the
# sprite's own bounds and the screen size, so game code needs no coordinate literals
# or sprite-size math. off_screen? / off_left? / off_right? / above_top? /
# below_bottom? each return a Condition; clamp_to_screen pins the sprite on screen.
# Pinned on the reference interpreter (the oracle); the shmup example exercises them
# on real hardware.
class TestSpriteScreenEdges < Minitest::Test
  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby

  # Place an 8x8 sprite at (px, py) and record `predicate.then { flag = 1 }`; return
  # the flag (1 if the predicate held at that position, else 0). The sprite starts on
  # screen and is moved to (px, py), so no coordinate literals appear in the helper
  # under test — only in the fixture that positions it.
  def flag_at(px, py, &predicate)
    b = Builder.new
    b.instance_eval do
      image(:dot, "#" => :red) { "########\n" * 8 } # 8x8, fully opaque -> hitbox is the whole tile
      screen :bitmap
      var :flag, 0
      s = sprite(:dot, at: [100, 80])
      s.move_to(px, py)
      predicate.call(s).then { set :flag, 1 }
      halt
    end
    b.emit_pending_functions
    Ruby.new.run(b.program)[:flag]
  end

  def test_below_bottom_is_true_only_when_fully_below_the_screen
    assert_equal 0, flag_at(100, 159, &:below_bottom?), "one pixel still on screen: not below yet"
    assert_equal 1, flag_at(100, 160, &:below_bottom?), "top at the screen height: fully below"
    assert_equal 1, flag_at(100, 220, &:below_bottom?)
  end

  def test_above_top_is_true_only_when_fully_above_the_screen
    assert_equal 0, flag_at(100, -7, &:above_top?), "one pixel still on screen: not above yet"
    assert_equal 1, flag_at(100, -8, &:above_top?), "bottom at y=0: fully above"
  end

  def test_off_left_is_true_only_when_fully_past_the_left_edge
    assert_equal 0, flag_at(-7, 80, &:off_left?), "one pixel still on screen"
    assert_equal 1, flag_at(-8, 80, &:off_left?), "right edge at x=0: fully off the left"
  end

  def test_off_right_is_true_only_when_fully_past_the_right_edge
    assert_equal 0, flag_at(239, 80, &:off_right?), "one pixel still on screen"
    assert_equal 1, flag_at(240, 80, &:off_right?), "left edge at the width: fully off the right"
  end

  def test_off_screen_is_true_past_any_edge_and_false_while_on_screen
    assert_equal 0, flag_at(100, 80, &:off_screen?), "squarely on screen"
    assert_equal 0, flag_at(-4, 80, &:off_screen?), "half off the left still shows: not off_screen"
    assert_equal 1, flag_at(-8, 80, &:off_screen?), "fully off the left"
    assert_equal 1, flag_at(100, 200, &:off_screen?), "fully off the bottom"
  end

  # clamp_to_screen pins the sprite's position so its box stays within the screen,
  # using the sprite's own size — no coordinate literals in game code.
  def clamped(px, py)
    b = Builder.new
    sx = sy = nil
    b.instance_eval do
      image(:dot, "#" => :red) { "########\n" * 8 }
      screen :bitmap
      s = sprite(:dot, at: [100, 80])
      s.move_to(px, py)
      s.clamp_to_screen
      sx = s.x.node[:name]
      sy = s.y.node[:name]
      halt
    end
    b.emit_pending_functions
    i = Ruby.new.run(b.program)
    [i[sx], i[sy]]
  end

  def test_clamp_to_screen_pulls_a_sprite_back_inside_each_edge
    assert_equal [0, 0], clamped(-50, -50), "past the top-left corner -> pinned to (0, 0)"
    assert_equal [232, 152], clamped(300, 300), "past the bottom-right -> pinned by the sprite's 8x8 size"
  end

  def test_clamp_to_screen_leaves_an_on_screen_sprite_where_it_is
    assert_equal [100, 80], clamped(100, 80)
  end

  # The helpers are shared through Bounds, so a plain Box gets the off-screen tests too.
  def test_a_box_also_answers_the_off_screen_tests
    b = Builder.new
    on = off = nil
    b.instance_eval do
      screen :bitmap
      var :on_flag, 0
      var :off_flag, 0
      box(10, 10, 20, 20).off_screen?.then { set :on_flag, 1 }   # on screen -> stays 0
      box(-40, 10, 20, 20).off_screen?.then { set :off_flag, 1 } # fully off the left -> 1
      halt
    end
    b.emit_pending_functions
    i = Ruby.new.run(b.program)
    assert_equal 0, i[:on_flag], "a box on screen is not off_screen?"
    assert_equal 1, i[:off_flag], "a box fully past the left edge is off_screen?"
  end
end

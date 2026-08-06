# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# A sprite that faces the way it moves: pass `facing:` a map of direction to image,
# and the sprite draws whichever pose it faces. face(:dir) turns it in place, and
# move(:dir) turns it as it goes. Tested with distinctly COLOURED poses (green
# right, red left) so "which pose is showing" is a pixel check — on the interpreter
# and on gemba. (The poses are the same size so they share one save-under buffer.)
class TestSpriteFacing < Minitest::Test
  include GembaSupport
  include RubyGBA::Constants

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  POSE = 2 # a 2x2 pose

  def faceted_program(frames:, &body)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      image(:face_r, "#" => :green) { "##\n##" } # first pose -> starts facing right
      image(:face_l, "#" => :red)   { "##\n##" }
      clear_screen :blue
      guy = sprite :guy, at: [50, 50], facing: { right: :face_r, left: :face_l }
      game_loop do
        wait_vblank
        after(frames) { halt }
        instance_exec(guy, &body) if body
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def count_color(screen, color)
    want = Color.resolve(color)
    n = 0
    240.times { |x| 160.times { |y| n += 1 if screen.pixel(x, y) == want } }
    n
  end

  def test_a_faceted_sprite_starts_on_its_first_pose
    s = Reference.new.run(faceted_program(frames: 3)).screen
    assert_equal Color.resolve(:green), s.pixel(50, 50), "should start on the first pose (right, green)"
    assert_equal POSE * POSE, count_color(s, :green)
    assert_equal 0, count_color(s, :red), "the other pose should not be drawn"
  end

  def test_face_swaps_the_pose_in_place_without_a_trail
    prog = faceted_program(frames: 6) { |guy| after(2) { guy.face :left } }
    s = Reference.new.run(prog).screen
    assert_equal Color.resolve(:red), s.pixel(50, 50), "face :left should show the left (red) pose"
    assert_equal POSE * POSE, count_color(s, :red), "exactly one pose of red — no smear"
    assert_equal 0, count_color(s, :green), "the old (right) pose was restored, not left behind"
  end

  def test_move_turns_the_sprite_to_face_its_direction
    prog = faceted_program(frames: 8) { |guy| guy.move :left, by: 1 }
    i = Reference.new.run(prog)
    assert_operator i[:__spr1_x], :<, 50, "move :left should move it left"
    assert_equal POSE * POSE, count_color(i.screen, :red), "moving left should also face left (red)"
    assert_equal 0, count_color(i.screen, :green), "it no longer faces right"
  end

  # ---- misuse ----

  def test_facing_a_direction_the_sprite_lacks_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      program = faceted_program(frames: 2) { |guy| guy.face :up } # only right/left were given
      Reference.new.run(program)
    end
    assert_match(/face/, err.message)
    assert_match(/up/, err.message)
  end

  def test_facing_a_plain_sprite_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        image(:ball, "#" => :white) { "##\n##" }
        sprite(:ball, at: [0, 0]).face(:left) # no facing: given
      end
    end
    assert_match(/poses/, err.message)
  end

  def test_poses_of_different_sizes_are_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        image(:big, "#" => :green) { "###\n###\n###" } # 3x3
        image(:small, "#" => :red) { "##\n##" }          # 2x2
        sprite :guy, at: [0, 0], facing: { right: :big, left: :small }
      end
    end
    assert_match(/same size/, err.message)
  end

  # ---- hardware ----

  def test_the_faced_pose_renders_on_gemba
    prog = faceted_program(frames: 6) { |guy| after(2) { guy.face :left } }
    rom = ROM.assemble(GBA.new.lower(prog), title: "FACING", code: "BFAC", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 7)
    assert v.red?(50, 50), "the left (red) pose should show on hardware — got #{v.pixel_gba(50, 50).to_s(16)}"
    refute v.green?(50, 50), "the right pose should have been restored"
  end
end

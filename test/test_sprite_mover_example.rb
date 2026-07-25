# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "../examples/sprite_mover"
require_relative "test_helper"

# The sprite_mover example, rewritten to use the `sprite` helper: the heart is a
# sprite that repaints itself, so the game loop no longer clears the screen or
# blits every frame. These assert the conversion actually holds — the redraw-
# everything pattern is gone from the loop — and that it still renders and steers,
# on the interpreter and on gemba.
class TestSpriteMoverExample < Minitest::Test
  include GembaSupport
  include RubyGBA::Constants

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  FIELD = RubyGBA::Color.rgb(4, 6, 14)
  START = [(SpriteMover::SCREEN_W - SpriteMover::SPRITE_W) / 2,
           (SpriteMover::SCREEN_H - SpriteMover::SPRITE_H) / 2].freeze

  # Whether +color+ is painted anywhere on screen.
  def color_on?(screen, color)
    (0...SpriteMover::SCREEN_H).any? { |y| (0...SpriteMover::SCREEN_W).any? { |x| screen.pixel(x, y) == color } }
  end

  # ---- the conversion: no per-frame clear or user blit in the loop ----

  def test_the_game_loop_no_longer_clears_or_blits_every_frame
    loop_node = SpriteMover.program.walk.find { |n| n.kind == :loop }
    refute_nil loop_node, "the example should have a game loop"
    # The framework's repaint blit is nested inside an `if` (the visibility guard),
    # so a bare clear_screen or blit among the loop's own statements would be the
    # old redraw-everything pattern. There should be none.
    kinds = loop_node.children.map(&:kind)
    refute_includes kinds, :clear_screen, "the loop still clears the screen every frame"
    refute_includes kinds, :blit, "the loop still blits the heart by hand every frame"
  end

  # ---- it renders and steers ----

  def test_the_heart_shows_up_and_moves_on_the_interpreter
    # Hold left for a while, then it settles against the left clamp.
    i = Ruby.new.input_each_frame { |_f| [:left] }.run(SpriteMover.program, max_steps: 4000)
    assert_operator i[:__spr1_x], :<, START[0], "holding left didn't move the heart"
    assert color_on?(i.screen, Color.resolve(:red)), "the heart isn't on screen"
    assert color_on?(i.screen, FIELD), "the blue field isn't showing around the heart"
  end

  def test_it_builds_a_rom
    assert SpriteMover.build_rom.size.positive?
  end

  def test_it_renders_and_steers_on_hardware
    rom = ROM.assemble(GBA.new.lower(SpriteMover.program), title: "SPRITEMV", code: "BSPM", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 10, keys: KEY_LEFT)
    # after sliding left, the heart's start column is field-blue again (no trail)
    assert v.pixel_is?(START[0] + 2, START[1] + 2, FIELD),
           "the start cell wasn't restored on hardware — got #{v.pixel_gba(START[0] + 2, START[1] + 2).to_s(16)}"
    # and the heart (red) is somewhere to the left of where it began
    moved = (10...START[0]).any? { |x| v.pixel_is?(x, START[1] + 2, :red) }
    assert moved, "the heart isn't found to the left on hardware"
  end
end

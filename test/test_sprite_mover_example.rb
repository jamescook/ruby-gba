# frozen_string_literal: true

require "test_helper"

require_relative "../examples/sprite_mover"

# The sprite_mover example, rewritten to use the `sprite` helper: the heart is a
# sprite that repaints itself, so the game loop no longer clears the screen or
# blits every frame. These assert the conversion actually holds — the redraw-
# everything pattern is gone from the loop — and that it still renders and steers,
# on the interpreter and on the emulator.
class TestSpriteMoverExample < Minitest::Test
  include RubyGBA::Constants

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
    i = Reference.new.input_each_frame { |_f| [:left] }.run(SpriteMover.program, max_steps: 4000)
    assert_operator i[:__spr1_x], :<, START[0], "holding left didn't move the heart"
    assert color_on?(i.screen, Color.resolve(:red)), "the heart isn't on screen"
    assert color_on?(i.screen, FIELD), "the blue field isn't showing around the heart"
  end

  def test_it_builds_a_rom
    assert SpriteMover.build_rom.size.positive?
  end

  # --- the two posts, which is what the stack is here to show ---
  #
  # Both posts are written AFTER the heart, so declaration order alone would put both in
  # front of it. The stack overrules that for one of them. Nineteen frames of holding a
  # direction is where the heart sits on a post — far enough to reach it, not so far it
  # has gone past (the heart moves two pixels a frame from the middle of the screen).

  ON_A_POST = 19
  POST_ROW = SpriteMover::POST_Y + 2

  def steered(direction)
    Reference.new.input_each_frame { |_f| [direction] }
             .run(SpriteMover.program, frames: ON_A_POST).screen
  end

  def test_the_heart_passes_in_front_of_the_post_in_the_back_layer
    assert_equal Color.resolve(:red),
                 steered(:left).pixel(SpriteMover::LEFT_POST_X + 1, POST_ROW),
                 "the left post is in :backdrop, so the heart must cover it"
  end

  def test_the_heart_passes_behind_the_post_in_the_front_layer
    shown = steered(:right).pixel(SpriteMover::RIGHT_POST_X + 1, POST_ROW)

    refute_equal Color.resolve(:red), shown,
                 "the right post is in :foreground, so it must cover the heart"
    refute_equal FIELD, shown, "the heart never reached the right post"
  end

  # The same thing the console draws, since this is the bug's whole point.
  def test_the_stack_holds_on_hardware
    rom = ROM.assemble(GBA.new.lower(SpriteMover.program), title: "SPRITEMV", code: "BSPM", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: ON_A_POST + 2, keys: KEY_LEFT)

    assert v.pixel_is?(SpriteMover::LEFT_POST_X + 1, POST_ROW, :red),
           "on hardware the heart did not cover the :backdrop post — got " \
           "#{format('0x%04x', v.pixel_gba(SpriteMover::LEFT_POST_X + 1, POST_ROW))}"
  end

  def test_it_renders_and_steers_on_hardware
    rom = ROM.assemble(GBA.new.lower(SpriteMover.program), title: "SPRITEMV", code: "BSPM", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 10, keys: KEY_LEFT)
    # after sliding left, the heart's start column is field-blue again (no trail)
    assert v.pixel_is?(START[0] + 2, START[1] + 2, FIELD),
           "the start cell wasn't restored on hardware — got #{v.pixel_gba(START[0] + 2, START[1] + 2).to_s(16)}"
    # and the heart (red) is somewhere to the left of where it began
    moved = (10...START[0]).any? { |x| v.pixel_is?(x, START[1] + 2, :red) }
    assert moved, "the heart isn't found to the left on hardware"
  end
end

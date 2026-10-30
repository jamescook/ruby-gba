# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/sprite_mover").to_s

# Where the example lays itself out, kept once for the cartridge's tests
# (test/lowering/gba/examples/test_sprite_mover_example_cartridge.rb).
module SpriteMoverPlaces
  include VBlank::Console::Hardware

  FIELD = VBlank::Graphics::Color.rgb(4, 6, 14)
  PLACES = Ractor.make_shareable(SpriteMover.layout(SCREEN_WIDTH, SCREEN_HEIGHT))
  START = PLACES[:heart]

  # Nineteen frames of holding a direction is where the heart sits on a post — far enough to
  # reach it, not so far it has gone past (the heart moves two pixels a frame from the middle of
  # the screen).
  ON_A_POST = 19
  POST_ROW = PLACES[:left_post][1] + 2
end

# The sprite_mover example, rewritten to use the `sprite` helper: the heart is a
# sprite that repaints itself, so the game loop no longer clears the screen or
# blits every frame. These assert the conversion actually holds — the redraw-
# everything pattern is gone from the loop — and that it still renders and steers,
# on the run's own player. The cartridge read back in the emulator is in
# test/lowering/gba/examples/test_sprite_mover_example_cartridge.rb.
class TestSpriteMoverExample < Minitest::Test
  include SpriteMoverPlaces

  # Whether +color+ is painted anywhere on screen.
  private def color_on?(screen, color)
    (0...SCREEN_HEIGHT).any? { |y| (0...SCREEN_WIDTH).any? { |x| screen.pixel(x, y) == color } }
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
    i = game_player.input_each_frame { |_f| [:left] }.run(SpriteMover.program, max_steps: 4000)
    assert_operator i[:__spr1_x], :<, START[0], "holding left didn't move the heart"
    assert color_on?(i.screen, Color.resolve(:red)), "the heart isn't on screen"
    assert color_on?(i.screen, FIELD), "the blue field isn't showing around the heart"
  end

  # --- the two posts, which is what the stack is here to show ---
  #
  # Both posts are written AFTER the heart, so declaration order alone would put both in
  # front of it. The stack overrules that for one of them. ON_A_POST frames of holding a
  # direction is where the heart sits on a post.

  private def steered(direction)
    game_player.input_each_frame { |_f| [direction] }
             .run(SpriteMover.program, frames: ON_A_POST).screen
  end

  def test_the_heart_passes_in_front_of_the_post_in_the_back_layer
    assert_equal Color.resolve(:red),
                 steered(:left).pixel(PLACES[:left_post][0] + 1, POST_ROW),
                 "the left post is in :backdrop, so the heart must cover it"
  end

  def test_the_heart_passes_behind_the_post_in_the_front_layer
    shown = steered(:right).pixel(PLACES[:right_post][0] + 1, POST_ROW)

    refute_equal Color.resolve(:red), shown,
                 "the right post is in :foreground, so it must cover the heart"
    refute_equal FIELD, shown, "the heart never reached the right post"
  end

  # The same thing the console draws, and the heart rendering and steering there, are in
  # test/lowering/gba/examples/test_sprite_mover_example_cartridge.rb.
end

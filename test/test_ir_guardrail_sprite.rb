# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The two sprite footgun guardrails, both advisory and both recognizing a sprite
# purely by structure (its repaint uses save/restore-region ops, which nothing
# else emits):
#   - SpriteClearedEachFrame: a loop that moves a sprite AND clears the screen
#     every frame — the clear wipes the sprite the framework just drew.
#   - ManualSpriteBlit: blitting, by hand, an image that's already a sprite —
#     a second, un-erased copy that smears a trail.
# Each test asserts the friendly warning fires on the misuse and stays quiet on the
# correct shipped example.
class TestSpriteGuardrails < Minitest::Test
  Builder = RubyGBA::Builder
  Cleared = RubyGBA::IR::Guardrails::Checks::SpriteClearedEachFrame
  Manual = RubyGBA::IR::Guardrails::Checks::ManualSpriteBlit

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def a_heart(&extra)
    program do
      screen :bitmap
      image(:heart, "#" => :red) { "##\n##" }
      clear_screen :blue
      hero = sprite :heart, at: [40, 40]
      game_loop do
        wait_vblank
        instance_exec(hero, &extra)
      end
    end
  end

  # ---- sprite + per-frame clear ----

  def test_flags_a_sprite_cleared_every_frame
    prog = a_heart { |hero| clear_screen :black; hero.x.add 1 }
    findings = Cleared.new.detect(prog)
    assert_equal 1, findings.length
    assert findings.first.warning?, "the check is advisory"
    assert_match(/every frame/, findings.first.message)
  end

  def test_flags_a_full_screen_fill_over_a_sprite
    prog = a_heart { |hero| dma_fill_rect 0, 0, 240, 160, :black; hero.x.add 1 }
    assert_equal 1, Cleared.new.detect(prog).length, "a full-screen fill is a clear too"
  end

  def test_does_not_flag_the_correct_sprite_mover
    require_relative "../examples/sprite_mover"
    assert_empty Cleared.new.detect(SpriteMover.program),
                 "sprite_mover clears once BEFORE the loop, not every frame"
  end

  def test_does_not_flag_a_clear_behind_a_press_edge
    # Clearing when a round (re)starts is a transition, not steady per-frame work.
    prog = a_heart { |hero| pressed(:start).then { clear_screen :black }; hero.x.add 1 }
    assert_empty Cleared.new.detect(prog), "a clear behind a pressed edge is a once-in-a-while transition"
  end

  # ---- manual blit of a sprite's image ----

  def test_flags_a_hand_blit_of_a_sprite_image
    prog = a_heart { |_hero| blit :heart, 80, 80 }
    findings = Manual.new.detect(prog)
    assert_equal 1, findings.length
    assert findings.first.warning?
    assert_match(/heart/, findings.first.message)
  end

  def test_does_not_flag_the_sprites_own_draws
    # sprite_mover's only blits are the framework's (the initial draw and the
    # per-frame repaint), so nothing should be flagged.
    require_relative "../examples/sprite_mover"
    assert_empty Manual.new.detect(SpriteMover.program), "the sprite's own draws aren't hand blits"
  end

  def test_does_not_flag_a_blit_of_a_non_sprite_image
    prog = program do
      screen :bitmap
      image(:coin, "#" => :yellow) { "##\n##" }
      game_loop do
        wait_vblank
        blit :coin, 10, 10 # a plain stamped image, no sprite involved
      end
    end
    assert_empty Manual.new.detect(prog), "a plain image blit isn't a sprite double-draw"
  end
end

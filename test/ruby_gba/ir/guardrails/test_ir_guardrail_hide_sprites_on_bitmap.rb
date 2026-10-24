# frozen_string_literal: true

require "test_helper"

require "stringio"

# `hide_sprites` on a bitmap screen. The console draws sprites as a layer of their own only on a
# screen drawn from tiles; a bitmap screen paints its sprites into the picture, so there is no
# layer to switch off and the call would do nothing at all.
class TestIRGuardrailHideSpritesOnBitmap < Minitest::Test
  Check = RubyGBA::IR::Guardrails::Checks::HideSpritesOnBitmap

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  def test_it_refuses_hide_sprites_on_a_bitmap_screen
    findings = Check.new.detect(program do
      screen :bitmap
      game_loop { hide_sprites }
    end)

    assert_equal 1, findings.size
    assert findings.first.error?
    assert_equal :hide_sprites, findings.first.node.kind
    assert_match(/hide_sprites/, findings.first.message)
    assert_match(/screen :tiled/, findings.first.message)
  end

  def test_a_tiled_game_is_not_flagged
    assert_empty(Check.new.detect(program do
      screen :tiled
      game_loop { hide_sprites }
    end))
  end

  # The screen is read per scene: a tiled scene of a game whose title is a bitmap one can.
  def test_a_tiled_scene_in_a_game_with_a_bitmap_scene_is_not_flagged
    prog = program do
      var :state, 0
      scene(:title) { screen :bitmap }
      scene(:play) do
        screen :tiled
        hide_sprites
      end
      game_loop { case_var(:state) { when_val 0, :title; when_val 1, :play } }
    end

    assert_empty Check.new.detect(prog)
  end

  def test_the_build_stops_and_explains
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("HIDE", out: StringIO.new, err: err) do
        screen :bitmap
        game_loop { hide_sprites }
      end
    end

    assert_match(/hide_sprites/, err.string)
  end
end

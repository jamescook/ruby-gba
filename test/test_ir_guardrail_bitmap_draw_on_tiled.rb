# frozen_string_literal: true

require "test_helper"

require "stringio"

# A drawing call the tiled screen can never show, inside a game that is otherwise
# a working tiled game.
#
# `fill_rect` writes pixels into the bitmap framebuffer. The tiled screen never
# reads that framebuffer — it paints tiles and composites sprites — so the call
# runs every frame and changes nothing. What makes this one nasty is that the rest
# of the game is fine: the background is right there on screen, so the display is
# obviously working, and the missing drawing looks like a bug in your own code.
#
# The first test PROVES that on the emulated console before any guardrail is
# involved. It builds the ROM straight from the builder's IR, not through
# RubyGBA.build, so it bypasses the validation pass and keeps proving the hardware
# behavior now that the guardrail stops such a program from being built.
class TestIRGuardrailBitmapDrawOnTiled < Minitest::Test

  Check = RubyGBA::IR::Guardrails::Checks::BitmapDrawOnTiled

  SOLID8 = (["########"] * 8).join("\n")
  FIELD = (["##############################"] * 20).freeze

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A tiled game with a blue background that also fills a red rectangle every
  # frame — the shape this guardrail exists for.
  def tiled_game_that_also_fills
    program do
      screen :tiled
      image(:blue_t, "#" => :blue) { SOLID8 }
      tiles :ground, "#" => :blue_t
      background :field, tiles: :ground, map: FIELD
      game_loop { fill_rect 100, 70, 40, 20, :red }
    end
  end

  # --- Proof that the footgun is real ---

  # The background paints and the fill does not. Both points come back the same
  # blue, so the red rectangle the game draws every frame simply is not there —
  # and the build that produced this ROM said nothing at all.
  def test_the_fill_never_reaches_the_console_but_the_background_does
    rom = ROM.assemble(GBA.new.lower(tiled_game_that_also_fills),
                       title: "GAP", code: "BGAP", maker: "01")

    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.blue?(20, 20), "the background should show"
    assert v.blue?(120, 80),
           "the middle of the fill_rect should still be background blue — a tiled screen " \
           "never reads the framebuffer, got 0x#{format('%04X', v.pixel_gba(120, 80))}"
    refute v.red?(120, 80), "red at (120, 80) would mean the fill landed after all"
  end

  # --- the check ---

  def test_it_flags_the_dead_draw_and_names_the_verb
    findings = Check.new.detect(tiled_game_that_also_fills)

    assert_equal 1, findings.size
    assert findings.first.error?, "a draw that can never show is a definite bug"
    assert_match(/fill_rect/, findings.first.message, "it names the verb the author typed")
    assert_match(/tiled screen/, findings.first.message)
    assert_equal :fill_rect, findings.first.node.kind, "it blames the draw itself"
  end

  def test_it_names_the_authors_verb_not_the_internal_kind
    prog = program do
      screen :tiled
      image(:blue_t, "#" => :blue) { SOLID8 }
      image(:hero, "#" => :red) { SOLID8 }
      tiles :ground, "#" => :blue_t
      background :field, tiles: :ground, map: FIELD
      game_loop { blit :hero, 10, 10 }
    end

    assert_match(/`blit`/, Check.new.detect(prog).first.message)
  end

  # --- what it must NOT flag ---

  # The headline false positive. On a tiled screen `draw_text`, `draw_number` and
  # `sprite` are composited as little hardware sprites, so they record `object`
  # nodes and never a bitmap draw. A tiled HUD is correct code and must stay quiet.
  def test_a_tiled_hud_is_not_flagged
    prog = program do
      screen :tiled
      image(:blue_t, "#" => :blue) { SOLID8 }
      image(:hero, "#" => :red) { SOLID8 }
      tiles :ground, "#" => :blue_t
      background :field, tiles: :ground, map: FIELD
      score = var :score, 0
      draw_text "SCORE", 8, 8, :white
      draw_number :score, 60, 8, :white, digits: 3
      hero = sprite :hero, at: [40, 40]
      game_loop { hero.x.add 1; score.add 1 }
    end

    assert_empty Check.new.detect(prog),
                 "a tiled HUD draws with hardware sprites, not with the framebuffer"
  end

  # A game may put a bitmap title in front of a tiled play field. The title's
  # `fill_rect` is correct where it sits, so the mode has to be read per scene
  # rather than per program.
  def test_a_bitmap_scene_inside_a_tiled_game_is_not_flagged
    prog = program do
      screen :tiled
      image(:blue_t, "#" => :blue) { SOLID8 }
      tiles :ground, "#" => :blue_t
      background :field, tiles: :ground, map: FIELD
      var :state, 0
      scene(:title) do
        screen :bitmap
        fill_rect 10, 10, 40, 20, :red
      end
      scene(:play) { }
      game_loop { case_var(:state) { when_val 0, :title; when_val 1, :play } }
    end

    assert_empty Check.new.detect(prog), "the title scene is a bitmap scene; its fill is correct"
  end

  # With nothing painting, this stays silent and leaves the case to
  # EmptyTiledScreen — which tells the author to change one line to
  # `screen :bitmap`. That advice is only right while there is no background to
  # throw away, so exactly one of the two checks speaks.
  def test_it_leaves_an_empty_tiled_screen_to_the_other_check
    prog = program do
      screen :tiled
      game_loop { fill_rect 100, 70, 40, 20, :red }
    end

    assert_empty Check.new.detect(prog)
    refute_empty RubyGBA::IR::Guardrails::Checks::EmptyTiledScreen.new.detect(prog),
                 "the empty-screen check owns this one"
  end

  def test_a_bitmap_game_is_not_flagged
    prog = program do
      screen :bitmap
      clear_screen :black
      game_loop { fill_rect 100, 70, 40, 20, :red }
    end

    assert_empty Check.new.detect(prog)
  end

  # --- the build surfaces it ---

  def test_the_build_stops_and_explains
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("GAP", code: "BGAP", maker: "01", out: StringIO.new, err: err) do
        screen :tiled
        image(:blue_t, "#" => :blue) { SOLID8 }
        tiles :ground, "#" => :blue_t
        background :field, tiles: :ground, map: FIELD
        game_loop { fill_rect 100, 70, 40, 20, :red }
      end
    end

    assert_match(/fill_rect/, err.string)
    assert_match(/background/, err.string, "it names what to use instead")
  end
end

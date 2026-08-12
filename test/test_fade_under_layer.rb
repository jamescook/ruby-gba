# frozen_string_literal: true

require "test_helper"
require_relative "differential"

# Placing a fade in the stack: `fade :black, 100, under: :ui` blends everything behind
# :ui and leaves :ui and anything in front of it alone. "Fade the game out and keep the
# score showing" is what a stack of layers is worth naming for.
#
# The thing to assert is the PICTURE — what is dark and what is still lit — on both
# backends, because the two reach it by completely different means. The console leaves
# background layers out of a blend mask and holds the blend off individual sprites with
# invisible twins of them; the interpreter paints back to front and blends each thing as
# it goes. Only the result is the contract.
class TestFadeUnderLayer < Minitest::Test
  include Differential

  WHITE = RubyGBA::Color.resolve(:white)
  GREEN = RubyGBA::Color.resolve(:green)
  BLACK = RubyGBA::Color.resolve(:black)

  # A tiled game with a green field, a white player sprite, and a white HUD — one thing
  # in each of three layers, so a fade can be placed between any two of them.
  #
  # The sample points: (20, 40) is field, (104, 84) is the player, and the HUD is read as
  # the brightest pixel anywhere in the text, since a glyph is mostly see-through and
  # which pixels a letter lights is the font's business.
  def game(amount, under: nil, place_hud: true)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :world, :actors, :ui
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      layer(:world) { background :field, tiles: :terrain, map: (0...32).map { "." * 32 } }
      layer(:actors) { sprite :guy, at: [100, 80] }
      if place_hud
        layer(:ui) { draw_text "SCORE", 8, 8, :white }
      else
        draw_text "SCORE", 8, 8, :white
      end
      game_loop { fade :black, amount, under: under }
    end
    b.emit_pending_functions
    b
  end

  def interpreted(builder, frames: 8)
    i = Reference.new.run(builder.program, frames: frames)
    reading { |x, y| i.screen.pixel(x, y) }
  end

  def on_console(builder, frames: 8)
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "FADEUNDER", code: "BFUL", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: frames)
    reading { |x, y| v.pixel_gba(x, y) }
  end

  def reading
    { field: yield(20, 40), player: yield(104, 84),
      hud: (8...48).flat_map { |x| (8...16).map { |y| yield(x, y) } }.max }
  end

  # --- the picture ---

  def test_a_fade_under_the_hud_leaves_the_hud_lit
    picture = interpreted(game(100, under: :ui))

    assert_equal BLACK, picture[:field], "the field is gone"
    assert_equal BLACK, picture[:player], "and so is the player"
    assert_equal WHITE, picture[:hud], "but the score is still readable"
  end

  def test_the_same_fade_with_no_layer_takes_the_hud_too
    picture = interpreted(game(100))

    assert_equal BLACK, picture[:hud], "a fade that names no layer is the whole screen"
  end

  # A line between the scenery and everything that moves: the field darkens and both the
  # player and the HUD stay lit. This is the case the console gets for nothing — every
  # sprite is on the kept side, so they leave the blend together and no twin is made.
  def test_a_fade_under_the_actors_keeps_every_sprite
    picture = interpreted(game(100, under: :actors))

    assert_equal BLACK, picture[:field]
    assert_equal WHITE, picture[:player]
    assert_equal WHITE, picture[:hud]
  end

  # ...and the backmost layer keeps everything, because there is nothing behind it.
  def test_a_fade_under_the_backmost_layer_changes_nothing
    picture = interpreted(game(100, under: :world))

    assert_equal GREEN, picture[:field]
    assert_equal WHITE, picture[:player]
    assert_equal WHITE, picture[:hud]
  end

  # Something that named no layer is never on the kept side. There is no place in the
  # stack to read for it, and an effect reaching what you did not say to keep is the
  # answer that surprises nobody.
  def test_a_hud_in_no_layer_fades_with_the_game
    picture = interpreted(game(100, under: :ui, place_hud: false))

    assert_equal BLACK, picture[:hud]
  end

  # The picture comes back untouched. A placed fade blends while the picture is built
  # rather than while it is read, so this is the assertion that the building is redone
  # from the source and nothing was blended into it for keeps.
  def test_the_picture_comes_back_when_the_fade_lifts
    picture = interpreted(game(0, under: :ui))

    assert_equal GREEN, picture[:field]
    assert_equal WHITE, picture[:player]
    assert_equal WHITE, picture[:hud]
  end

  # --- on the console ---

  def test_the_console_fades_the_game_and_keeps_the_hud
    picture = on_console(game(100, under: :ui))

    assert_equal BLACK, picture[:field], "the field is gone"
    assert_equal BLACK, picture[:player], "and so is the player"
    assert_equal WHITE, picture[:hud], "but the score is still readable"
  end

  def test_the_console_agrees_with_the_interpreter_about_what_is_kept
    %i[world actors ui].each do |layer|
      assert_equal interpreted(game(100, under: layer)), on_console(game(100, under: layer)),
                   "under :#{layer}"
    end
  end

  # A whole-screen fade in the same program still takes everything, because the twins
  # that hold a fade off the HUD are shown only while the fade is behind them.
  def test_a_whole_screen_fade_beside_a_placed_one_still_covers_the_hud
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :world, :ui
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      layer(:world) { background :field, tiles: :terrain, map: (0...32).map { "." * 32 } }
      layer(:ui) { draw_text "SCORE", 8, 8, :white }
      whole = var :whole, 0
      game_loop do
        (whole == 1).then { fade :black, 100 }
                    .else { fade :black, 100, under: :ui }
        whole.set 1
      end
    end
    b.emit_pending_functions

    rom = ROM.assemble(GBA.new.lower(b.program), title: "BOTH", code: "BFUB", maker: "01")
    lit = ->(v) { (8...48).flat_map { |x| (8...16).map { |y| v.pixel_gba(x, y) } }.max }

    assert_equal WHITE, lit.call(assert_gemba_loads_rom(rom, frames: 2)),
                 "the first frame places the fade under the HUD, which stays lit"
    assert_equal BLACK, lit.call(assert_gemba_loads_rom(rom, frames: 8)),
                 "and from the second frame the whole-screen fade takes it too"
  end

  # --- what it refuses ---

  def test_a_layer_that_is_not_in_the_stack_is_refused
    error = assert_raises(ArgumentError) { game(100, under: :nope) }

    assert_match(/no layer named :nope/, error.message)
    assert_match(/:world, :actors, :ui/, error.message, "and it says what the stack is")
  end

  def test_a_fade_under_a_layer_on_a_bitmap_screen_is_refused
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        layers :world, :ui
        fade :black, 100, under: :ui
      end
    end

    assert_match(/needs `screen :tiled`/, error.message)
  end

  def test_a_fade_under_a_layer_with_no_stack_declared_is_refused
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :tiled
        fade :black, 100, under: :ui
      end
    end

    assert_match(/declares no layers/, error.message)
  end

  def test_under_takes_a_layer_name
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :tiled
        layers :world, :ui
        fade :black, 100, under: "ui"
      end
    end

    assert_match(/layer name after `under:`/, error.message)
  end

  # Every kept sprite needs a second slot in the sprite table, so a big HUD can run the
  # table out. The error names the two counts and what to do, rather than failing deep in
  # the slot arithmetic.
  def test_keeping_more_sprites_than_the_table_holds_is_refused
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :world, :actors, :ui
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      layer(:world) { background :field, tiles: :terrain, map: (0...32).map { "." * 32 } }
      layer(:actors) { sprite :guy, at: [100, 80] } # something the fade does reach
      layer(:ui) { draw_text "A" * 70, 0, 8, :white }
      game_loop { fade :black, 100, under: :ui }
    end
    b.emit_pending_functions

    error = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { GBA.new.lower(b.program) }

    assert_match(/kept out of a fade/, error.message)
    assert_match(/second slot/, error.message)
  end

  # --- the effect pack carries the layer through ---

  def pack_game(under:)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :world, :ui
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      layer(:world) { background :field, tiles: :terrain, map: (0...32).map { "." * 32 } }
      layer(:ui) { draw_text "SCORE", 8, 8, :white }
      started = var :started, 0
      game_loop do
        (started == 0).then { fade_out under: under, frames: 4 }
        started.set 1
      end
    end
    b.emit_pending_functions
    b
  end

  def test_fade_out_takes_a_layer_and_the_hud_survives_the_ramp
    picture = interpreted(pack_game(under: :ui), frames: 12)

    assert_equal BLACK, picture[:field], "the field faded out over the ramp"
    assert_equal WHITE, picture[:hud], "and the score is still readable"
  end

  # The pack is one ramp, so it sits in one place. Two is the single set of blend
  # registers showing through, and it is said rather than silently arbitrated.
  def test_the_pack_refuses_two_places_for_one_fade
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :tiled
        layers :world, :actors, :ui
        game_loop do
          fade_out under: :ui
          fade_out under: :actors
        end
      end
    end

    assert_match(/one screen fade/, error.message)
  end

  # --- what it costs ---

  # The fade family is otherwise free — it tells the display what to show and redraws
  # nothing — so the one member that is not gets a line of its own rather than joining
  # the sprite tally beside it.
  def test_explain_names_what_keeping_the_hud_costs
    out = StringIO.new
    RubyGBA::IR::CostModel.new.render(game(100, under: :ui).program, out: out, color: :never)

    assert_match(/keeping 5 sprites out of the fade under :ui/, out.string)
  end

  def test_a_fade_that_keeps_every_sprite_costs_nothing_extra
    out = StringIO.new
    RubyGBA::IR::CostModel.new.render(game(100, under: :actors).program, out: out, color: :never)

    refute_match(/keeping/, out.string, "no sprite needs holding out of it one at a time")
  end

  # ...and it is charged at a weight of its OWN, measured on the emulator beside the sprite
  # write it used to borrow. A window is not a second sprite: where it stands, which pose it
  # holds and how big it is are the sprite's own numbers, copied into its slot on the way
  # past. Charged as a whole sprite each — which the model did until it was measured — a
  # kept HUD reads a quarter too dear, in a report where every number beside it is measured.
  def test_a_kept_sprite_is_charged_less_than_a_whole_sprite_write
    weights = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS
    verdict = RubyGBA::IR::CostModel.new.kept_sprites_verdict(game(100, under: :ui).program)

    assert_in_delta verdict.sprites * weights[:obj_window_write], verdict.cost, 1e-9
    assert_operator weights[:obj_window_write], :<, weights[:obj_write],
                    "a window rides its sprite's numbers, so it cannot cost a whole sprite write"
  end

  # --- the whole screen, both backends ---

  def test_every_pixel_agrees_with_the_console
    assert_backends_agree(game(100, under: :ui).program, frames: 4)
  end

  def test_every_pixel_agrees_when_the_fade_keeps_every_sprite
    assert_backends_agree(game(100, under: :actors).program, frames: 4)
  end
end

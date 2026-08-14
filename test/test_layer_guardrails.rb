# frozen_string_literal: true

require "test_helper"
require "stringio"

# The layer guardrails, as a set.
#
# They come in two kinds, and the split is about WHEN the mistake is knowable.
#
# An argument mistake is wrong the moment it is typed — a layer that is not in the
# stack, a `layer` block inside another one — so it RAISES where it was written and
# the message names that line. Waiting until the end to mention it would be worse
# advice at a worse time.
#
# A whole-program mistake needs the finished tree. A layer holds nothing only once
# every declaration in every scene has run, and whether the screen honors the stack
# depends on the screen mode the program settled on. Those are WARNINGS from the
# guardrail pass, and they are advisory: the game builds and runs, and the picture is
# simply not the one the stack describes.
#
# The model these guard — which layer each declaration lands in — is test_layers.rb.
# The errors `fade ... under:` raises are with the feature, in test_fade_under_layer.rb.
class TestLayerGuardrails < Minitest::Test
  Checks = RubyGBA::IR::Guardrails::Checks

  # A program plus the software sprites the build collected. Both, because a software
  # sprite's layer lives on its handle and never reaches the tree — the reason the two
  # whole-program checks are handed the build's sprites instead of walking alone.
  # Two pictures every test can draw with, declared up front so no test spends a line
  # on art. A picture is not a thing in the stack, so declaring one changes nothing
  # either check looks at.
  def built(&block)
    b = Builder.new
    b.image(:red_guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
    b.image(:blue_guy, "#" => :blue) { (["#" * 8] * 8).join("\n") }
    b.instance_eval(&block)
    b.emit_pending_functions
    [b.program, b.sprites]
  end

  # Some checks need the build's software sprites (a sprite's layer lives on its handle,
  # not in the tree) and some read the tree alone. Hand the list only to the ones that
  # take it, so a check that stops needing it says so by its own signature.
  def findings(check, &block)
    program, sprites = built(&block)
    made = check.instance_method(:initialize).arity.zero? ? check.new : check.new(sprites)
    made.detect(program)
  end

  def only_finding(check, &block)
    found = findings(check, &block)

    assert_equal 1, found.length, "expected exactly one finding, got #{found.map(&:message)}"
    found.first
  end

  # ==========================================================================
  # ERRORS — wrong the moment they are typed
  # ==========================================================================

  # --- the stack itself ---

  def test_declaring_the_stack_twice_is_refused
    error = assert_raises(ArgumentError) do
      built do
        layers :world, :ui
        layers :actors
      end
    end

    assert_match(/already declared/, error.message)
    assert_match(/:world, :ui/, error.message)
  end

  def test_naming_a_layer_twice_in_the_stack_is_refused
    error = assert_raises(ArgumentError) { built { layers :ui, :world, :ui } }

    assert_match(/:ui/, error.message)
    assert_match(/more than one time/, error.message)
  end

  def test_a_stack_with_no_names_is_refused
    error = assert_raises(ArgumentError) { built { layers } }

    assert_match(/at least one name/, error.message)
  end

  def test_a_stack_of_something_other_than_names_is_refused
    error = assert_raises(ArgumentError) { built { layers :world, "ui" } }

    assert_match(/takes names/, error.message)
  end

  # --- opening a layer ---

  def test_a_layer_needs_a_block
    error = assert_raises(ArgumentError) { built { layers(:ui) && layer(:ui) } }

    assert_match(/needs a block/, error.message)
  end

  def test_a_layer_that_was_never_declared_is_refused_and_the_stack_is_shown
    error = assert_raises(ArgumentError) do
      built do
        layers :world, :ui
        layer(:actors) { nil }
      end
    end

    assert_match(/no layer named :actors/, error.message)
    assert_match(/:world, :ui/, error.message)
  end

  def test_a_layer_in_a_program_with_no_stack_says_to_declare_one
    error = assert_raises(ArgumentError) { built { layer(:ui) { nil } } }

    assert_match(/declares no layers/, error.message)
    assert_match(/layers :ui/, error.message)
  end

  def test_a_layer_inside_a_layer_is_refused
    error = assert_raises(ArgumentError) do
      built do
        layers :world, :ui
        layer(:world) { layer(:ui) { nil } }
      end
    end

    assert_match(/cannot hold another `layer` block/, error.message)
  end

  # --- routines: the layer cannot reach the body ---
  #
  # A routine's body is built after the `layer` block has closed, so a declaration in it
  # would quietly get no depth. What is refused is that DECLARATION, not the routine —
  # see the tests further down for why the difference is the whole design.

  def test_a_sprite_declared_in_a_func_in_a_layer_is_refused_and_says_which_way_round_works
    error = assert_raises(ArgumentError) do
      built do
        screen :tiled
        layers :actors
        layer(:actors) { func(:setup) { sprite :red_guy, at: [10, 10] } }
      end
    end

    assert_match(/A sprite declared inside `func :setup`/, error.message)
    assert_match(/built later/, error.message)
    assert_match(/put the `layer` block inside the func/, error.message)
  end

  # The hole this closes: `once_a_frame` has exactly the shape a `func` has, and used to
  # say nothing at all.
  def test_a_sprite_declared_in_a_once_a_frame_in_a_layer_is_refused
    error = assert_raises(ArgumentError) do
      built do
        screen :tiled
        layers :actors
        layer(:actors) { once_a_frame { sprite :red_guy, at: [10, 10] } }
      end
    end

    assert_match(/A sprite declared inside `once_a_frame`/, error.message)
    # The advice differs from the func's on purpose: a declaration in a per-frame body
    # runs once wherever it is put, so moving it out is both the fix and what was meant.
    assert_match(/declare it outside/, error.message)
  end

  def test_the_refusal_names_the_routine_the_author_named
    error = assert_raises(ArgumentError) do
      built do
        screen :tiled
        layers :actors
        layer(:actors) { once_a_frame(:wobble) { sprite :red_guy, at: [10, 10] } }
      end
    end

    assert_match(/`once_a_frame :wobble`/, error.message)
  end

  def test_a_background_declared_in_a_deferred_body_in_a_layer_is_refused
    error = assert_raises(ArgumentError) do
      built do
        screen :tiled
        image(:tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
        tiles :set, "#" => :tile
        layers :sky
        layer(:sky) { once_a_frame { background :bg, tiles: :set, map: (0...4).map { "#" * 4 } } }
      end
    end

    assert_match(/A background declared inside `once_a_frame`/, error.message)
  end

  # A scene is refused where it is WRITTEN, whatever it turns out to declare, and the
  # reason is different in kind: not that the layer cannot reach the body, but that a
  # state of the game holds things at many depths and a layer is one.
  def test_a_scene_inside_a_layer_is_refused_for_holding_many_depths
    error = assert_raises(ArgumentError) do
      built do
        layers :actors
        layer(:actors) { scene(:playing) { nil } }
      end
    end

    assert_match(/many depths/, error.message)
  end

  # --- routines that must go on working, which is why the rule is on the hazard ---
  #
  # `pulse`, `camera_follows`, `fade_out` and `shake_screen` are all built on the PUBLIC
  # `once_a_frame`, so a rule that refused the verb could not tell a pack from an author
  # and would refuse `pulse coin` on the line after the coin — exactly where a game
  # writes it. Asking instead what the body DECLARED lets every one of them through,
  # because a per-frame body is behavior and puts nothing in the picture.

  EFFECTS_IN_A_LAYER = {
    "pulse" => ->(sprite, _bg) { pulse sprite, to: 1.5 },
    "camera_follows" => ->(sprite, bg) { camera_follows sprite, across: bg },
    "fade_out" => ->(_sprite, _bg) { fade_out frames: 10 },
    "shake_screen" => ->(_sprite, _bg) { shake_screen intensity: 3, frames: 8 },
  }.freeze

  EFFECTS_IN_A_LAYER.each do |verb, effect|
    define_method(:"test_#{verb}_still_works_inside_a_layer") do
      program, = built do
        screen :tiled
        image(:tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
        tiles :set, "#" => :tile
        layers :world, :actors
        world = layer(:world) { background :bg, tiles: :set, map: (0...20).map { "#" * 30 } }
        layer(:actors) do
          hero = sprite :red_guy, at: [100, 60]
          instance_exec(hero, world, &effect)
        end
        game_loop { fade_in }
      end

      assert_equal [:actors], program.walk.filter_map { |node| node.layer if node.kind == :object }
    end
  end

  # And a plain routine that declares nothing with a depth can live beside the sprite it
  # moves, which the old rule refused for no reason a picture could tell.
  def test_a_func_that_declares_nothing_drawable_can_sit_beside_its_sprite
    program, = built do
      screen :tiled
      layers :actors
      x = var :x, 0
      layer(:actors) do
        sprite :red_guy, at: [10, 10]
        func(:move) { x.add 1 }
      end
      game_loop { call :move }
    end

    assert_equal [:actors], program.walk.filter_map { |node| node.layer if node.kind == :object }
  end

  def test_a_once_a_frame_that_declares_nothing_drawable_is_left_alone
    program, = built do
      screen :tiled
      layers :actors
      x = var :x, 0
      layer(:actors) do
        sprite :red_guy, at: [10, 10]
        once_a_frame { x.add 1 }
      end
      game_loop { nil }
    end

    assert_equal [:actors], program.walk.filter_map { |node| node.layer if node.kind == :object }
  end

  # --- drawing: a layer holds things, not brushstrokes ---

  # Each of these paints into the picture at the moment it is called, so no ordering
  # applied later can reach back and change where it landed.
  PAINTING = {
    "pixel" => -> { pixel 10, 10, :red },
    "fill_rect" => -> { fill_rect 0, 0, 10, 10, :red },
    "dma_fill_rect" => -> { dma_fill_rect 0, 0, 10, 10, :red },
    "draw_rect_at" => -> { draw_rect_at 0, 0, 10, 10, :red },
    "clear_screen" => -> { clear_screen :red },
    "blit" => -> { blit :red_guy, 4, 4 },
  }.freeze

  PAINTING.each do |verb, body|
    define_method(:"test_#{verb}_inside_a_layer_is_refused") do
      error = assert_raises(ArgumentError) do
        built do
          screen :bitmap
          layers :world
          layer(:world) { instance_exec(&body) }
        end
      end

      assert_match(/`#{verb}` paints where you call it/, error.message)
      assert_match(/To fix this/, error.message)
    end
  end

  # Text is the one verb whose nature changes with the screen, so its error has to say
  # which of the two the author is in — the same verb IS layerable on a tiled screen.
  def test_bitmap_text_inside_a_layer_is_refused_and_names_the_screen_kind
    error = assert_raises(ArgumentError) do
      built do
        screen :bitmap
        layers :ui
        layer(:ui) { draw_text "HI", 8, 8, :white }
      end
    end

    assert_match(/`draw_text` paints where you call it on a `screen :bitmap`/, error.message)
  end

  # The node a live number records is a digit glyph; the author wrote `draw_number`, and
  # that is the word the error has to use.
  def test_bitmap_numbers_inside_a_layer_are_refused_by_the_verb_that_was_written
    error = assert_raises(ArgumentError) do
      built do
        screen :bitmap
        var :score, 0
        layers :ui
        layer(:ui) { draw_number :score, 8, 8, :white }
      end
    end

    assert_match(/`draw_number` paints where you call it/, error.message)
    refute_match(/draw_digit/, error.message)
  end

  def test_a_whole_screen_effect_inside_a_layer_is_refused
    error = assert_raises(ArgumentError) do
      built do
        screen :bitmap
        layers :world
        layer(:world) { fade :black, 50 }
      end
    end

    assert_match(/changes the whole screen/, error.message)
  end

  # A fade is placed, not contained — and that is worth teaching where somebody has
  # just tried to contain one, rather than leaving them to find it.
  def test_refusing_a_fade_in_a_layer_says_a_fade_can_be_placed_instead
    error = assert_raises(ArgumentError) do
      built do
        screen :tiled
        layers :world, :ui
        layer(:ui) { fade :black, 50 }
      end
    end

    assert_match(/under: :ui/, error.message)
  end

  def test_moving_the_camera_inside_a_layer_is_refused
    error = assert_raises(ArgumentError) do
      built do
        screen :bitmap
        layers :world
        layer(:world) { camera 4, 0 }
      end
    end

    assert_match(/changes the whole screen/, error.message)
  end

  # ==========================================================================
  # WARNINGS — only the finished program can see them
  # ==========================================================================

  # --- a layer nothing is in ---

  def test_a_layer_nothing_is_in_is_named_with_the_two_ways_it_happens
    finding = only_finding(Checks::LayerHoldsNothing) do
      screen :tiled
      layers :world, :ui
      layer(:world) { sprite :red_guy, at: [10, 10] }
      game_loop { nil }
    end

    assert_equal :layer_holds_nothing, finding.check
    assert_predicate finding, :warning?
    assert_match(/:ui holds nothing/, finding.message)
    assert_match(/written differently/, finding.message) # a typo's surviving half
    assert_match(/remove it from the `layers` line/, finding.message)
  end

  # A `layer` block that ran and placed nothing is the same mistake read from the
  # picture: what matters is that no thing is at that depth, not whether a block
  # opened it.
  def test_a_layer_block_that_placed_nothing_is_the_same_finding
    finding = only_finding(Checks::LayerHoldsNothing) do
      screen :tiled
      layers :world, :ui
      layer(:world) { sprite :red_guy, at: [10, 10] }
      layer(:ui) { var :score, 0 }
      game_loop { nil }
    end

    assert_match(/:ui holds nothing/, finding.message)
  end

  def test_more_than_one_empty_layer_is_one_finding_naming_them_all
    finding = only_finding(Checks::LayerHoldsNothing) do
      screen :tiled
      layers :world, :ui, :over
      layer(:world) { sprite :red_guy, at: [10, 10] }
      game_loop { nil }
    end

    assert_match(/:ui, :over/, finding.message)
  end

  # Every layer empty is a different mistake — the stack was declared and then never
  # used — so it gets the advice that fits it, not the same sentence three times.
  def test_a_stack_used_by_nothing_at_all_says_what_a_layer_block_is_for
    finding = only_finding(Checks::LayerHoldsNothing) do
      screen :tiled
      layers :world, :ui
      sprite :red_guy, at: [10, 10]
      game_loop { nil }
    end

    assert_match(/puts nothing in any of them/, finding.message)
    assert_match(/`layer` block/, finding.message)
    refute_match(/holds nothing\./, finding.message)
  end

  # A software sprite's layer is on its handle, not in the tree. A check that walked
  # the tree alone would call every layer of a bitmap game empty.
  def test_a_layer_holding_only_software_sprites_is_not_called_empty
    assert_empty findings(Checks::LayerHoldsNothing) {
      screen :bitmap
      layers :back, :front
      layer(:back) { sprite :red_guy, at: [16, 16] }
      layer(:front) { sprite :blue_guy, at: [30, 30] }
      game_loop { nil }
    }
  end

  # A layer can earn its place by being the LINE an effect sits at: `fade under: :cut`
  # keeps everything from :cut forward, so :cut decides what the fade reaches without
  # holding anything itself.
  def test_a_layer_used_only_as_the_line_for_a_fade_is_in_use
    assert_empty findings(Checks::LayerHoldsNothing) {
      screen :tiled
      layers :world, :cut, :ui
      layer(:world) { sprite :red_guy, at: [10, 10] }
      layer(:ui) { sprite :blue_guy, at: [20, 20] }
      fade :black, 100, under: :cut
      game_loop { nil }
    }
  end

  def test_a_game_that_declares_no_layers_is_left_alone
    assert_empty findings(Checks::LayerHoldsNothing) {
      screen :tiled
      sprite :red_guy, at: [10, 10]
      game_loop { nil }
    }
  end

  # --- a stack the screen does not honor ---

  # SPRITES ARE NOT WARNED ABOUT ANY MORE, because the picture is now right: the frame
  # boundary repaints them in stack order. Warning here would be a false alarm, so the
  # test that used to demand one now demands silence — and test_layers.rb asserts the
  # pixel that proves it.
  def test_a_bitmap_stack_that_reverses_two_sprites_is_left_alone
    assert_empty findings(Checks::StackNotHonored) {
      screen :bitmap
      layers :front, :back # :back is the FRONT of the stack, so the two disagree
      layer(:back) { sprite :red_guy, at: [16, 16] }
      layer(:front) { sprite :blue_guy, at: [16, 16] }
      game_loop { nil }
    }
  end

  # A background is the half that stays permanent: it stamps itself into the one picture
  # where it is declared, and nothing draws it again.
  def test_two_bitmap_backgrounds_the_stack_reverses_are_warned_about
    finding = reversed_background_finding

    assert_equal :stack_not_honored, finding.check
    assert_predicate finding, :warning?
    assert_match(/`screen :bitmap`/, finding.message)
    assert_match(/`screen :tiled`/, finding.message) # the fix
  end

  # Both orders, because "your stack says one thing and the screen will do another" is
  # only useful if it says which is which.
  def test_the_warning_shows_the_order_asked_for_and_the_order_the_screen_gives
    finding = reversed_background_finding

    assert_match(/asks for :far, :near/, finding.message)
    assert_match(/will show :near, :far/, finding.message)
  end

  # ...and it says sprites are fine, so nobody reads the warning as covering them too.
  def test_the_warning_says_sprites_are_not_affected
    assert_match(/[Ss]prites are not affected/, reversed_background_finding.message)
  end

  # A background paints once, where it is declared, and every sprite is painted over it
  # every frame after that. So no layer can put a background in FRONT of a sprite here,
  # and this is the case the sprite fix does not reach.
  def test_a_bitmap_background_put_in_front_of_a_sprite_is_warned_about
    finding = only_finding(Checks::StackNotHonored) do
      screen :bitmap
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      layers :actors, :scenery
      layer(:actors) { sprite :red_guy, at: [16, 16] }
      layer(:scenery) { background :bg, tiles: :terrain, map: (0...4).map { "." * 4 } }
      game_loop { nil }
    end

    assert_match(/:bg/, finding.message)
  end

  # The finding three tests share. `built` runs its block with the BUILDER as `self`, so
  # the setup has to be handed the builder rather than called bare — a bare call would
  # look for a DSL verb of that name.
  def reversed_background_finding
    test = self
    only_finding(Checks::StackNotHonored) { test.two_reversed_backgrounds(self) }
  end

  # Two backgrounds on a bitmap screen whose layers reverse the order they were declared
  # in — the near one written first, the stack asking for the far one behind it. The one
  # arrangement the screen cannot give, since each stamped itself where it was written.
  def two_reversed_backgrounds(builder)
    builder.screen :bitmap
    builder.image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
    builder.tiles :terrain, "." => :grass
    builder.layers :far, :near
    map = (0...4).map { "." * 4 }
    builder.layer(:near) { builder.background :near, tiles: :terrain, map: map }
    builder.layer(:far) { builder.background :far, tiles: :terrain, map: map }
    builder.game_loop { nil }
  end

  # The usual arrangement — declared back to front — is the one a bitmap screen paints
  # anyway. Warning there would be a false alarm on a game whose picture is right.
  def test_a_bitmap_stack_that_agrees_with_the_declarations_is_left_alone
    assert_empty findings(Checks::StackNotHonored) {
      screen :bitmap
      layers :back, :front
      layer(:back) { sprite :red_guy, at: [16, 16] }
      layer(:front) { sprite :blue_guy, at: [30, 30] }
      game_loop { nil }
    }
  end

  # The same stack the bitmap screen cannot give, on the screen that can. Its sprites
  # are the console's, so the build's software-sprite list is empty and there is
  # nothing here to mistake for a painted thing.
  def test_the_same_stack_on_a_tiled_screen_is_left_alone
    assert_empty findings(Checks::StackNotHonored) {
      screen :tiled
      layers :front, :back
      layer(:back) { sprite :red_guy, at: [16, 16] }
      layer(:front) { sprite :blue_guy, at: [16, 16] }
      game_loop { nil }
    }
  end

  # Backgrounds DO reach the check from either screen, so a tiled one has to be told
  # apart by the mode it draws in. Two tiled backgrounds whose layers reverse the order
  # they were declared in are exactly what the tile hardware is for — this is parallax
  # with the near layer written first — and saying anything here would be a false alarm.
  def test_tiled_backgrounds_the_stack_reverses_are_left_alone
    assert_empty findings(Checks::StackNotHonored) {
      screen :tiled
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      layers :far, :near
      layer(:near) { background :trees, tiles: :terrain, map: (0...4).map { "." * 4 } }
      layer(:far) { background :sky, tiles: :terrain, map: (0...4).map { "." * 4 } }
      game_loop { nil }
    }
  end

  def test_a_bitmap_game_that_declares_no_layers_is_left_alone
    assert_empty findings(Checks::StackNotHonored) {
      screen :bitmap
      sprite :red_guy, at: [16, 16]
      sprite :blue_guy, at: [30, 30]
      game_loop { nil }
    }
  end

  # ==========================================================================
  # THE SET IS REGISTERED
  # ==========================================================================

  # Both warnings report from the build rather than the tree, so they are appended per
  # build the way the leftover-Condition check is. That is easy to leave out, and a
  # check nobody runs is worse than no check — so build a real ROM and read the stream
  # a person building one reads.
  def test_a_real_build_reports_a_layer_that_holds_nothing
    err = StringIO.new
    RubyGBA.build("LAYERS", code: "BLYR", maker: "01", err: err) do
      screen :tiled
      image(:red_guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :world, :ui
      layer(:world) { sprite :red_guy, at: [10, 10] }
      game_loop { nil }
    end

    assert_match(/:ui holds nothing/, err.string)
  end

  def test_a_real_build_reports_a_stack_the_screen_does_not_honor
    err = StringIO.new
    map = (0...4).map { "." * 4 }
    RubyGBA.build("LAYERS", code: "BLYR", maker: "01", err: err) do
      screen :bitmap
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      layers :far, :near
      layer(:near) { background :near, tiles: :terrain, map: map }
      layer(:far) { background :far, tiles: :terrain, map: map }
      game_loop { nil }
    end

    assert_match(/stack asks for a background order that screen does not give/, err.string)
  end

  # ...and the same build with SPRITES in a reversed stack says nothing at all, because
  # that picture is now the one the stack asked for.
  def test_a_real_build_says_nothing_about_a_reversed_sprite_stack
    err = StringIO.new
    RubyGBA.build("LAYERS", code: "BLYR", maker: "01", err: err) do
      screen :bitmap
      image(:red_guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:blue_guy, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      layers :front, :back
      layer(:back) { sprite :red_guy, at: [16, 16] }
      layer(:front) { sprite :blue_guy, at: [16, 16] }
      game_loop { nil }
    end

    refute_match(/stack_not_honored/, err.string)
  end

  # Advisory, both of them: the ROM is still built and still runs. A warning that
  # stopped the build would make a stack something you cannot adopt a bit at a time.
  def test_neither_warning_stops_the_build
    rom = RubyGBA.build("LAYERS", code: "BLYR", maker: "01", err: StringIO.new) do
      screen :tiled
      image(:red_guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :world, :ui
      layer(:world) { sprite :red_guy, at: [10, 10] }
      game_loop { nil }
    end

    assert RubyGBA::ROMValidator.check(rom).ok?
  end
end

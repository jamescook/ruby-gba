# frozen_string_literal: true

require "test_helper"

# Layers — `layers` to name the depths a picture is built from, `layer do ... end` to
# put things in them.
#
# What is under test here is the MODEL: which layer each declaration ended up in. The
# friendly errors and warnings a layer brings with it are a set of their own, in
# test_layer_guardrails.rb. What each layer becomes on a console, and the drawing order
# that follows from it, is asserted with the backends.
class TestLayers < Minitest::Test
  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Every node of a kind, anywhere in the tree (a scene's declarations live in a func
  # body, so a top-level scan would miss them).
  def nodes(prog, kind)
    prog.walk.select { |node| node.kind == kind }
  end

  def layers_of(prog, kind)
    nodes(prog, kind).map(&:layer)
  end

  # A tiled game with one background and one sprite, each in its own layer.
  def stacked_game(&extra)
    program do
      screen :tiled
      layers :scenery, :actors, :ui
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass

      layer :scenery do
        background :world, tiles: :terrain, map: (0...20).map { "." * 30 }
      end
      layer :actors do
        sprite :guy, at: [100, 60]
      end
      instance_eval(&extra) if extra
    end
  end

  # --- the stack itself ---

  def test_the_declared_stack_is_recorded_in_the_order_it_was_written
    prog = program { layers :sky, :world, :actors, :ui }

    assert_equal [%i[sky world actors ui]], nodes(prog, :layers).map(&:names)
  end

  def test_a_program_that_names_no_layers_declares_no_stack
    prog = program { screen :bitmap }

    assert_empty nodes(prog, :layers)
  end

  # The claim that makes this safe to land before anything reads it: a game that never
  # says `layers` builds exactly the tree it built before layers existed. A field that
  # was never set doesn't appear on a node, so this is checked by asking for the whole
  # tree as data rather than by asking each node whether its layer is nil.
  def test_nothing_in_a_program_without_layers_carries_one
    prog = program do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      sprite :guy, at: [10, 10]
    end

    refute_includes prog.to_h.to_s, "layer",
                    "a program that names no layers must build the tree it always did"
  end

  # --- what lands in a layer ---

  def test_a_background_takes_the_layer_it_was_declared_in
    assert_equal [:scenery], layers_of(stacked_game, :background)
  end

  def test_a_hardware_sprite_takes_the_layer_it_was_declared_in
    assert_equal [:actors], layers_of(stacked_game, :object)
  end

  def test_a_sprite_handle_says_which_layer_it_is_in
    hero = nil
    stacked_game { hero = sprite :guy, at: [8, 8] } # outside any layer block

    assert_nil hero.layer
  end

  def test_a_software_sprite_takes_the_layer_it_was_declared_in
    hero = nil
    program do
      screen :bitmap
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :world, :actors
      layer(:actors) { hero = sprite :guy, at: [10, 10] }
    end

    assert_equal :actors, hero.layer
  end

  # Tiled text is drawn as one hardware-sprite glyph per character, so putting a HUD in
  # a layer has to reach every one of them, not just the first.
  def test_tiled_text_puts_every_glyph_in_the_layer
    prog = stacked_game do
      layer :ui do
        draw_text "HI", 8, 8, :white
        draw_number :score, 8, 20, :white, digits: 2
      end
    end
    hud = nodes(prog, :object).reject { |node| node.layer == :actors }

    assert_operator hud.length, :>=, 4, "two letters and two digits are four glyphs"
    assert_equal [:ui], hud.map(&:layer).uniq
  end

  def test_a_spriteful_pool_puts_every_slot_in_the_layer
    prog = stacked_game do
      layer :actors do
        pool :shot, x: 0, y: 0, image: :guy, capacity: 4
      end
    end

    # The hero plus one object per pool slot, all in :actors.
    assert_equal [:actors], layers_of(prog, :object).uniq
    assert_equal 5, nodes(prog, :object).length
  end

  # A layer says WHERE IN THE STACK and a scene says WHEN. They are different axes, so
  # a sprite can be in both and neither has to know about the other.
  def test_a_layer_inside_a_scene_holds_for_that_scene_only
    prog = program do
      screen :tiled
      layers :actors, :ui
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      var :state, 0
      scene(:playing) { layer(:actors) { sprite :guy, at: [10, 10] } }
      scene(:over) { layer(:ui) { sprite :guy, at: [20, 20] } }
      game_loop { case_var(:state) { when_val 0, :playing; when_val 1, :over } }
    end

    assert_equal %i[actors ui], layers_of(prog, :object)
  end

  def test_a_layer_block_runs_on_the_build_so_a_part_in_its_own_file_works
    inside = nil
    b = Builder.new
    b.instance_eval do
      layers :actors
      layer(:actors) { inside = self }
    end

    assert_same b, inside, "the block must run on the build, or `Enemies.new(self)` cannot work"
  end

  # A layer holding one thing reads as one line, which is how a sprite in a layer is
  # most often written.
  def test_a_layer_hands_back_what_its_block_ended_on
    hero = nil
    program do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :actors
      hero = layer(:actors) { sprite :guy, at: [10, 10] }
    end

    assert_equal :actors, hero.layer
  end

  def test_a_variable_declared_beside_a_sprite_is_not_nagged
    prog = stacked_game do
      layer :actors do
        var :speed, 2
        set :speed, 3
      end
    end

    assert_equal 2, nodes(prog, :set).count { |node| node.var == :speed }
  end

  # --- an effect verb keeps working beside the sprite it acts on ---

  # `pulse` and its siblings declare a routine that runs every frame. That routine is
  # behavior, not a thing in the picture, so it must not trip the rule that refuses an
  # authored `func` — a game says `pulse coin` on the line after it declares the coin.
  def test_an_effect_verb_works_inside_a_layer
    prog = stacked_game do
      layer :actors do
        coin = sprite :guy, at: [50, 50]
        pulse coin, to: 1.5
      end
    end

    assert_equal 2, nodes(prog, :object).length
  end

  def test_a_fade_effect_verb_works_inside_a_layer
    prog = stacked_game do
      layer :actors do
        fade_out frames: 10
      end
      game_loop { nil }
    end

    assert_operator nodes(prog, :fade).length, :>=, 1
  end

  # A game loop's body runs where it is written, so the layer reaches it and a sprite
  # declared inside gets the depth it looks like it gets. It is allowed for that reason
  # — unlike a `func`, whose body the layer provably cannot reach.
  def test_a_game_loop_inside_a_layer_puts_its_declarations_in_that_layer
    prog = program do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :actors
      layer(:actors) { game_loop { sprite :guy, at: [10, 10] } }
    end

    assert_equal [:actors], layers_of(prog, :object)
  end

  # A frame repaints every software sprite with the very nodes an author's `blit`
  # builds. Nobody wrote them inside the layer block, so they must not be refused as
  # if somebody had.
  def test_a_frame_can_be_paced_from_inside_a_layer_on_a_bitmap_screen
    prog = program do
      screen :bitmap
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :actors
      layer(:actors) do
        hero = sprite :guy, at: [10, 10]
        game_loop { hero.move :right, by: 1 }
      end
    end

    assert_equal 1, nodes(prog, :wait_vblank).length
  end

  # A software sprite paints itself onto the screen the moment it is declared, and takes
  # itself off again every frame. That painting is the framework's, not the author's, so
  # it must not be mistaken for a brushstroke written inside the layer block.
  def test_a_software_sprite_can_be_declared_in_a_layer_though_it_paints_itself
    prog = program do
      screen :bitmap
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :actors
      layer(:actors) { sprite :guy, at: [10, 10] }
    end

    # The very node an author's `blit` builds, put there by the sprite itself.
    assert_equal 1, nodes(prog, :blit).length
  end

  # --- both screens honor the stack for sprites ---
  #
  # The picture, not the tree. Two sprites overlapping in layers that REVERSE the order
  # they were declared in: the one in front must be the one the stack put there, and both
  # screen kinds must agree on which that is.

  OVERLAP = [60, 60].freeze

  def two_reversed_sprites(kind)
    program do
      screen kind
      image(:pillar, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:heart, "#" => :red) { (["#" * 8] * 8).join("\n") }
      clear_screen :blue if kind == :bitmap
      layers :behind, :front
      # The pillar declared FIRST but placed at the FRONT, so declaration order and the
      # stack disagree on purpose.
      layer(:front) { sprite :pillar, at: OVERLAP }
      layer(:behind) { sprite :heart, at: OVERLAP }
      game_loop { nil }
    end
  end

  def shown_where_they_overlap(kind)
    Reference.new.run(two_reversed_sprites(kind), frames: 3)
             .screen.pixel(OVERLAP[0] + 3, OVERLAP[1] + 3)
  end

  def test_a_bitmap_screen_shows_the_sprite_the_stack_puts_in_front
    assert_equal Color.resolve(:green), shown_where_they_overlap(:bitmap),
                 "the front layer's sprite must win, not the one declared last"
  end

  def test_a_tiled_screen_shows_the_same_one
    assert_equal Color.resolve(:green), shown_where_they_overlap(:tiled)
  end

  def test_the_two_screens_agree
    assert_equal shown_where_they_overlap(:bitmap), shown_where_they_overlap(:tiled)
  end

  # ...and the console draws what the interpreter says.
  def test_the_console_shows_the_front_layer_too
    rom = assemble_rom(two_reversed_sprites(:bitmap), name: "STACK")
    v = assert_gemba_loads_rom(rom, frames: 6)

    assert v.green?(OVERLAP[0] + 3, OVERLAP[1] + 3),
           "console showed #{format('0x%04x', v.pixel_gba(OVERLAP[0] + 3, OVERLAP[1] + 3))}"
  end

  # --- the classification is complete ---

  # Every kind of drawing has an answer to "can this go in a layer", so a new one has to
  # be classified on purpose rather than falling into whichever answer a lookup defaults
  # to. Without this a new drawing verb would silently be allowed in a layer and silently
  # do nothing there.
  def test_every_kind_of_drawing_says_whether_it_can_go_in_a_layer
    drawing = RubyGBA::IR::Nodes.by_kind.select { |_, type| type.category == :draw }.keys
    missing = drawing - RubyGBA::Builder::Layers::IN_A_LAYER.keys

    assert_empty missing,
                 "these drawing kinds are not classified — add them to " \
                 "Builder::Layers::IN_A_LAYER: #{missing.inspect}"
  end

  def test_nothing_is_classified_that_is_not_drawing
    drawing = RubyGBA::IR::Nodes.by_kind.select { |_, type| type.category == :draw }.keys
    stray = RubyGBA::Builder::Layers::IN_A_LAYER.keys - drawing

    assert_empty stray, "these are classified but are not drawing kinds: #{stray.inspect}"
  end

  # --- it survives the whole build ---

  def test_a_layered_game_builds_a_rom
    rom = RubyGBA.build("LAYERS", code: "BLYR", maker: "01") do
      screen :tiled
      layers :scenery, :actors
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass

      layer(:scenery) { background :world, tiles: :terrain, map: (0...20).map { "." * 30 } }
      hero = layer(:actors) { sprite :guy, at: [100, 60] }
      game_loop { hero.move :right, by: 1 }
    end

    assert RubyGBA::ROMValidator.check(rom).ok?
  end

  # The interpreter has to make a picture out of a layered program, not choke on the
  # stack it declares — the sprite in :actors is drawn where it was put.
  def test_a_layered_game_draws_on_the_reference_interpreter
    prog = stacked_game { game_loop { nil } }
    i = Reference.new.run(prog, max_steps: 200_000)

    assert_equal RubyGBA::Color.resolve(:red), i.screen.pixel(104, 64)
  end
end

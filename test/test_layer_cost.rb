# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT EACH DEPTH COSTS A FRAME — the layer axis of the cost report.
#
# It is a different axis from the cost tree, which is what makes it worth having. The
# tree groups by the shape of the program (a case_var, a scene, a func, a repeat) and
# answers "where in my code". A layer groups by depth in the picture and answers "where
# on screen". A sprite in :actors inside scene :playing is in both, so neither can be a
# branch of the other and this is a roll-up printed beside the tree.
#
# What the numbers MEAN is asserted here; what the section looks like is one test, since
# the wording is free to improve.
class TestLayerCost < Minitest::Test
  Verdict = RubyGBA::IR::CostModel::Verdict

  def built(&block)
    b = Builder.new
    b.image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
    b.image(:tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def costs(&block)
    program = built(&block)
    RubyGBA::IR::CostModel.new.layer_verdicts(program).to_h { |v| [v.name, v.cost] }
  end

  # A tiled game: scenery at the back, two sprites over it, a HUD on top.
  def stacked
    built do
      screen :tiled
      tiles :set, "#" => :tile
      var :score, 0
      layers :sky, :actors, :ui
      layer(:sky) { background :bg, tiles: :set, map: (0...20).map { "#" * 30 } }
      layer(:actors) do
        sprite :guy, at: [10, 10]
        sprite :guy, at: [40, 10]
      end
      layer(:ui) { draw_number :score, 8, 8, :white, digits: 3 }
      game_loop { nil }
    end
  end

  def explain(program)
    out = StringIO.new
    RubyGBA::IR::CostModel.new.render(program, out: out, color: false)
    out.string
  end

  # --- what a depth costs ---

  def test_every_declared_layer_gets_an_answer_including_the_free_ones
    found = RubyGBA::IR::CostModel.new.layer_verdicts(stacked)

    assert_equal %i[sky actors ui], found.map(&:name)
    assert(found.all? { |v| v.is_a?(Verdict::Layer) })
  end

  # A tiled background is drawn by the display, so it costs the frame nothing once it is
  # up — however big it is. That zero is the point of the whole tiled screen, and a
  # report that hid it would teach the opposite.
  def test_a_background_that_only_sits_there_costs_a_frame_nothing
    assert_equal 0, costs {
      screen :tiled
      tiles :set, "#" => :tile
      layers :sky
      layer(:sky) { background :bg, tiles: :set, map: (0...20).map { "#" * 30 } }
      game_loop { nil }
    }[:sky]
  end

  def test_a_layer_of_sprites_costs_what_presenting_them_costs
    found = costs do
      screen :tiled
      layers :few, :many
      layer(:few) { sprite :guy, at: [10, 10] }
      layer(:many) { 3.times { |i| sprite :guy, at: [i * 20, 40] } }
      game_loop { nil }
    end

    assert_operator found[:few], :>, 0
    assert_in_delta found[:few] * 3, found[:many], 1e-9,
                    "three of the same sprite must cost three times one"
  end

  # A HUD is one hardware sprite per character, so a scoreboard is quietly the biggest
  # thing in the stack — the answer the whole section exists to give.
  def test_a_hud_of_glyphs_is_counted_glyph_by_glyph
    found = RubyGBA::IR::CostModel.new.layer_verdicts(stacked).to_h { |v| [v.name, v.cost] }

    assert_operator found[:ui], :>, found[:actors],
                    "three digits cost more than two sprites"
  end

  def test_a_background_the_game_scrolls_costs_its_layer_something
    found = costs do
      screen :tiled
      tiles :set, "#" => :tile
      layers :still, :moving
      layer(:still) { background :back, tiles: :set, map: (0...20).map { "#" * 30 } }
      near = layer(:moving) { background :front, tiles: :set, map: (0...20).map { "#" * 30 } }
      game_loop { near.scroll_by 1, 0 }
    end

    assert_equal 0, found[:still]
    assert_operator found[:moving], :>, 0
  end

  # A bend is the dearest thing a background can do and it belongs to one — so the layer
  # holding it has to carry it, or the section would report a rounding error for a game
  # whose whole frame is that layer.
  def test_a_background_that_bends_carries_that_cost_in_its_layer
    program = built do
      screen :tiled
      tiles :set, "#" => :tile
      wave = table :wave, (0...256).map { |i| i % 4 }
      layers :shore, :water
      layer(:shore) { background :back, tiles: :set, map: (0...20).map { "#" * 30 } }
      surf = layer(:water) { background :front, tiles: :set, map: (0...20).map { "#" * 30 } }
      surf.scroll_each_row { |row| wave[row] }
      game_loop { nil }
    end
    m = RubyGBA::IR::CostModel.new
    found = m.layer_verdicts(program).to_h { |v| [v.name, v.cost] }

    assert_equal 0, found[:shore]
    assert_in_delta m.bend_verdict(program).cost, found[:water], 1e-9
  end

  # --- the numbers add up ---

  # The invariant that makes the section trustworthy: what the depths cost, added up, is
  # exactly what the frame was charged for that work. It caught a real mistake — adding
  # raw weights per sprite where the quick-memory discount applies to the STATEMENT, which
  # made a stack cost more than the whole frame it sits in.
  def test_the_layers_add_up_to_what_the_frame_was_charged
    program = stacked
    m = RubyGBA::IR::CostModel.new
    total = m.layer_verdicts(program).sum(&:cost)
    charged = m.as_json(program)[:tree].sum { |category| category[:cost] }

    assert_in_delta charged, total, 1e-9,
                    "this game draws nothing but its stack, so the two must be the same number"
  end

  # Nothing in a layer is charged twice, and nothing out of one is charged at all: the
  # stack of a game that also does plenty of other work stays a fraction of the frame.
  def test_work_at_no_depth_is_not_counted_as_a_layer_cost
    program = built do
      screen :tiled
      layers :actors
      layer(:actors) { sprite :guy, at: [10, 10] }
      x = var :x, 0
      game_loop { 40.times { x.add 1 } }
    end
    m = RubyGBA::IR::CostModel.new
    stack = m.layer_verdicts(program).sum(&:cost)

    assert_operator stack, :<, m.steady_cost(program) / 2,
                    "a game that mostly computes must not read as mostly stack"
  end

  def test_a_game_that_declares_no_layers_has_no_layer_costs
    assert_empty RubyGBA::IR::CostModel.new.layer_verdicts(built {
      screen :tiled
      sprite :guy, at: [10, 10]
      game_loop { nil }
    })
  end

  # --- the report ---

  def test_the_stack_section_names_each_layer_its_cost_and_what_it_holds
    report = explain(stacked)

    assert_match(/:sky\s+background :bg/, report)         # free: no number at all
    assert_match(/:actors\s+~\S+\s+2 sprites/, report)
    assert_match(/:ui\s+~\S+\s+3 sprites/, report)
  end

  # THE HONESTY CONSTRAINT. Most of a frame sits at no depth, so a column of numbers with
  # nothing to measure them against reads as if the game cost what the stack costs. The
  # share has to be measured against what a frame pays EVERY time, not the worst-case
  # total the tree shows, or an every-frame number gets divided by a worst case.
  def test_the_section_says_what_share_of_the_frame_it_accounts_for
    program = stacked
    report = explain(program)
    m = RubyGBA::IR::CostModel.new
    recurring = m.steady_cost(program) + m.standing_costs(program)

    assert_match(/these layers cost ~\S+ of the ~#{Regexp.escape(format('%.1f', recurring))} /, report)
    assert_match(/sits at no depth/, report)
  end

  # A whole stack of scenery the display draws for nothing is a real answer, not a
  # missing one, and it reads better as a sentence than as a column of zeros.
  def test_a_stack_that_costs_nothing_says_so_in_words
    report = explain(built do
      screen :tiled
      tiles :set, "#" => :tile
      layers :sky
      layer(:sky) { background :bg, tiles: :set, map: (0...20).map { "#" * 30 } }
      game_loop { nil }
    end)

    assert_match(/these layers cost nothing a frame/, report)
  end

  def test_the_costs_are_in_the_json_beside_the_other_verdicts
    json = RubyGBA::IR::CostModel.new.as_json(stacked)

    assert_equal %i[sky actors ui], json[:layers].map { |l| l[:name] }
    assert(json[:layers].all? { |l| l.key?(:cost) })
  end

  def test_a_game_with_no_stack_carries_an_empty_list_in_the_json
    json = RubyGBA::IR::CostModel.new.as_json(built {
      screen :tiled
      sprite :guy, at: [10, 10]
      game_loop { nil }
    })

    assert_empty json[:layers]
  end
end

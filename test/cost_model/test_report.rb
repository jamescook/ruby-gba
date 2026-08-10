# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# The text and the JSON (lib/ruby_gba/ir/cost_model/report.rb): what a person reads
# when a build explains itself.
class TestCostReport < CostModelTest
  # A static program reports its one-time boot draw.
  def test_report_states_the_boot_cost_of_a_static_program
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    Cost.new.report(prog, out: io)
    assert_match(/boot cost .* scanlines/, io.string)
    assert_match(/done once/, io.string)
  end

  # A game loop that draws far more than a frame's budget is flagged.
  def test_report_flags_a_loop_that_overruns_the_budget
    prog = program do
      screen :bitmap
      game_loop do
        repeat(100) { |_i| clear_screen :black } # 100 * 38,400 ≫ budget
      end
    end
    io = StringIO.new
    Cost.new.report(prog, out: io)
    assert_match(/estimate over budget/, io.string)
  end

  # A ROM built through RubyGBA.build can report on itself.
  def test_a_built_rom_explains_itself
    rom = RubyGBA.build("EXPLAIN", code: "BXPL", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    rom.explain(out: io)
    assert_match(/boot cost .* scanlines/, io.string)
  end

  # rom.explain(format: :json) emits structured data tests can parse directly.
  def test_json_explain_is_parseable_structured_data
    rom = RubyGBA.build("JSON", code: "BJSN", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    rom.explain(format: :json, out: io)
    data = JSON.parse(io.string)
    near plot_rect(10, 10), data["frame_cost"]
    assert_equal false, data["looping"]
    # The tree is now organized into drawing / sound / logic sections; the fill_rect
    # sits inside the drawing section.
    assert_equal "drawing", data["tree"].first["category"]
    assert_equal "fill_rect", data["tree"].first["children"].first["op"]
    assert_equal "drawing", data["categories"].first["category"]
  end

  # rom.explain names the intent: a timed trigger reads as "every 30" in the cost
  # tree, because the interval survives on the IR node for the report to read.
  def test_rom_explain_names_a_timed_trigger
    prog = program do
      screen :bitmap
      game_loop do
        every(30) { draw_rect_at 0, 0, 8, 8, :green }
      end
    end
    io = StringIO.new
    Cost.new.render(prog, out: io)
    assert_match(/every 30/, io.string)
  end

  # The whole point of the drill-down: a reader can see WHAT their dearest work is, not
  # only that it is dear. A divide used to be priced right and then labelled with the
  # statement it fed, so the word never appeared and the biggest number in a raycaster
  # read as "set".
  def test_explain_names_a_divide_and_how_often_a_frame_does_it
    prog = program do
      screen :bitmap
      step = var :step, 3
      x = var :x, 100
      game_loop { repeat(30) { |_i| x.set(x / step) } }
    end
    text = rendered(prog)
    assert_match(/divide \(worked out\)/, text, "the tree names it")
    assert_match(/divide \(worked out\) ×30/, text, "and the hottest list counts a frame's worth")
  end

  # Dropping the walk from the recurring load is only safe while the ceiling is still
  # stated. A game CAN reach it, so the estimate says so instead of quietly losing it.
  def test_the_estimate_names_the_collision_worst_case
    io = StringIO.new
    Cost.new.render(near_misses, out: io)

    refute_match(/over budget/, io.string)
    assert_match(/collision is the worst case/, io.string)
    assert_match(/box test/, io.string, "and says why a typical frame does not pay it")
  end

  # THE ONE ASSUMPTION IN THE BUDGET AN AUTHOR CAN CORRECT. The every-frame figure turns on
  # how long a list usually is, and nothing in a program says it — so the report says which
  # number it used and where that number came from. Left silent, a reader would take the
  # verdict for a fact about their game when half of it is an assumption about their list.
  def test_the_estimate_says_what_it_took_a_list_to_hold
    io = StringIO.new
    Cost.new.render(list_walking_game(estimate: { usually: 6 }), out: io)

    assert_match(/a list walk counts what the list usually holds/, io.string)
    assert_match(/:body 6 of 64/, io.string, "the number it used, out of the capacity")
    assert_match(/the length you gave/, io.string, "and that the author is the one who said it")
  end

  # ...and when nobody said, it says that it guessed, and how to answer it.
  def test_a_guessed_length_says_so_and_says_how_to_answer_it
    io = StringIO.new
    Cost.new.render(list_walking_game, out: io)

    assert_match(/:body 16 of 64, a guess/, io.string)
    assert_match(/estimate: \{ usually: N \}/, io.string, "and how to say the real length")
  end

  # THE ONE THING AN AUTHOR CAN ACT ON about a loop. A loop that keeps its counter in a
  # register costs a fraction of one that cannot, and what stops it is always something in the
  # body — so the line says which shape the loop got and, when it is the dear one, what put it
  # there. A call moved out of a loop is worth most of what the loop costs.
  #
  # The shape is the BUILD's answer and travels with the ROM, so this reads a built one.
  def test_the_tree_says_which_shape_each_loop_got
    rom = RubyGBA.build("LOOPS", code: "BLPR", maker: "01", err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      total = var :total, 0
      b = self
      func(:bump) { total.add 1 }
      game_loop do
        b.repeat(8) { total.add 1 }
        b.repeat(8) { b.call :bump }
      end
    end
    io = StringIO.new
    rom.cost_model.render(rom.source_program, out: io, color: false)

    assert_match(/the loop itself \(in registers\)/, io.string)
    assert_match(/the loop itself \(through memory — the body calls :bump\)/, io.string)
  end

  # ...and the hottest list splits the two shapes apart, because that is the line a reader
  # reaches for and a hot loop's tree row is often collapsed behind a call. It groups on the
  # shape alone — the reason belongs to one loop, the total to all of them.
  def test_the_hottest_list_counts_the_two_shapes_apart
    rom = RubyGBA.build("LOOPS", code: "BLPH", maker: "01", err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      total = var :total, 0
      b = self
      func(:bump) { total.add 1 }
      game_loop do
        b.repeat(64) { total.add 1 }
        b.repeat(64) { b.call :bump }
      end
    end
    io = StringIO.new
    rom.cost_model.render(rom.source_program, out: io, color: false)
    hottest = io.string[/hottest:.*/m]

    assert_match(/the loop itself \(in registers\) ×64/, hottest)
    assert_match(/the loop itself \(through memory\) ×64/, hottest)
    refute_match(/calls :bump/, hottest, "the reason belongs to the one loop, not the total")
  end

  # A program handed to the model with no build behind it has no such answer — the shapes are
  # decided by the lowering — so the line says what a loop costs and claims nothing about how.
  def test_a_program_with_no_build_behind_it_claims_nothing_about_the_shape
    io = StringIO.new
    Cost.new.render(program { screen(:bitmap); game_loop { repeat(8) { add :n, 1 } } }, out: io)

    assert_match(/the loop itself/, io.string)
    refute_match(/in registers|through memory/, io.string)
  end

  def test_a_program_that_walks_no_list_says_nothing_about_one
    io = StringIO.new
    Cost.new.render(program { screen(:bitmap); game_loop { clear_screen :black } }, out: io)

    refute_match(/list walk/, io.string)
  end

  def list_walking_game(estimate: nil)
    program do
      screen :bitmap
      body = list :body, capacity: 64, estimate: estimate
      game_loop { repeat(body.length) { |_i| draw_rect_at 0, 0, 8, 8, :green } }
    end
  end

  def test_a_program_with_no_collision_says_nothing_about_collision
    prog = program do
      screen :bitmap
      game_loop { clear_screen :black }
    end
    io = StringIO.new
    Cost.new.render(prog, out: io)

    refute_match(/collision/, io.string)
  end

  # The JSON carries the applicable budget and the buffered flag, for tests/tools.
  def test_json_reports_the_mode_and_its_budget
    assert_equal Cost::FRAME_BUDGET, Cost.new.as_json(loop_of_clears(2, buffered: true))[:budget]
    assert_equal true, Cost.new.as_json(loop_of_clears(2, buffered: true))[:buffered]
    assert_equal false, Cost.new.as_json(loop_of_clears(2, buffered: false))[:buffered]
  end

  # The AC: a fitting sample-playing game still reads GREEN — the mixer is expected
  # work, not an alarm. Its worst case (all voices) is well under the whole frame.
  def test_a_sample_playing_game_reads_green
    io = StringIO.new
    Cost.new.render(sample_game, out: io)
    assert_match(/software mixer/, io.string)
    assert_match(/estimate within budget/, io.string)
    refute_predicate Cost.new.mixer_verdict(sample_game), :over?, "the mixer's worst case still fits the frame"
  end
end

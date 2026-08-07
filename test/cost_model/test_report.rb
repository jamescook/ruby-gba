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
    refute Cost.new.mixer_verdict(sample_game)[:over], "the mixer's worst case still fits the frame"
  end
end

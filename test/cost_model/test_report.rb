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

  # One scene runs a frame, so the dispatch costs its dearest arm and the rest weigh
  # nothing. The case line says so, once, where a reader sees a parent equal to one of its
  # children and would otherwise have to work out why.
  def test_the_case_line_says_only_the_dearest_scene_counts
    prog = program do
      screen :bitmap
      var :state, 0
      scene(:title) { fill_rect 0, 0, 8, 8, :blue }
      scene(:play)  { clear_screen :red }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end

    assert_match(/case_var :state \(the dearest scene\)/, rendered(prog))
  end

  # A ROM built through RubyGBA.build can be priced by the model that knows how it was built.
  def test_a_built_rom_can_be_priced_from_its_own_build_record
    rom = RubyGBA.build("EXPLAIN", code: "BXPL", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    io = StringIO.new
    rom.cost_model.render(rom.source_program, out: io)
    assert_match(/boot cost .* scanlines/, io.string)
  end

  # The model emits structured data tests can parse directly.
  def test_json_is_parseable_structured_data
    rom = RubyGBA.build("JSON", code: "BJSN", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red # 100
      halt
    end
    data = JSON.parse(JSON.generate(rom.cost_model.as_json(rom.source_program)))
    # A fixed-size fill is a straight run of stores, so a built cartridge prices it by
    # counting what the lowering emitted — a hundred pixels' worth, within a rounding of the
    # per-pixel weight that used to stand for the same instructions.
    assert_in_delta plot_rect(10, 10), data["frame_cost"], 0.05
    assert_equal false, data["looping"]
    # The tree is now organized into drawing / sound / logic sections; the fill_rect
    # sits inside the drawing section.
    assert_equal "drawing", data["tree"].first["category"]
    assert_equal "fill_rect", data["tree"].first["children"].first["op"]
    assert_equal "drawing", data["categories"].first["category"]
  end

  # The model names the intent: a timed trigger reads as "every 30" in the cost
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

  # WHICH FRAME EACH NUMBER IS ABOUT. The tree prices the frame a thing runs on; the budget
  # judges what every frame pays. Those are different numbers whenever work sits behind a
  # timed trigger, and the report used to lead with the first and judge the second with
  # nothing at the top saying so.
  def timed_game
    program do
      screen :bitmap
      total = var :total, 0
      b = self
      game_loop do
        b.every(6) { b.repeat(200) { total.add 1 } }
        total.add 1
      end
    end
  end

  def test_the_two_frames_are_named_apart_at_the_top
    text = rendered(timed_game)

    assert_match(/every frame ~\s*[\d.]+ scanlines\s+\(what the budget below judges\)/, text)
    assert_match(/worst frame ~\s*[\d.]+ scanlines\s+\(the tree below prices this one\)/, text)
  end

  # ...and a body that does not run every frame carries what it really costs one, which is
  # what joins the two totals up.
  def test_a_timed_body_says_what_an_average_frame_pays_for_it
    assert_match(/every 6\s+\(~[\d.]+ on an average frame\)/, rendered(timed_game))
  end

  # The hottest list is the one a reader acts on, so it ranks the frame the player pays for:
  # a body firing one frame in six is counted at a sixth, not whole.
  def test_the_hottest_list_ranks_an_average_frame
    text = rendered(timed_game)
    hottest = text[/hottest[^\n]*:.*/m]

    assert_match(/hottest, on an average frame:/, text)
    # 200 passes one frame in six is about 33 an average frame, not 200.
    assert_match(/×3[0-9]\b/, hottest, "a sixth of two hundred, not two hundred")
    refute_match(/×200\b/, hottest, "counting it whole is the frame nobody plays")
  end

  # A program with nothing timed pays the same every frame, and then one line says it once
  # rather than two lines saying it twice.
  def test_a_game_with_one_frame_says_it_once
    text = rendered(program do
      screen :bitmap
      total = var :total, 0
      game_loop { total.add 1 }
    end)

    assert_match(/per frame ~/, text)
    refute_match(/worst frame/, text)
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

  # ...AND DOES NOT NAME COLLISION IN A GAME THAT HAS NONE. The same line covers every reason
  # the worst frame and the usual one disagree, and collision was once the only one — so a
  # first-person view, whose walls are as tall as the distance says and whose worst frame is a
  # wall against your face, was told its worst case was per-pixel collision. It has no sprites.
  def test_a_game_with_no_collision_is_not_told_its_worst_case_is_collision
    prog = program do
      screen :bitmap, tear_free: true
      h = var :h, 40
      game_loop { repeat(20) { |col| draw_rect_at col * 12, 0, 12, h, :red } }
    end
    text = rendered(prog)

    refute_match(/collision/, text, "there is not a sprite in this program")
    assert_match(/the worst frame costs ~/, text, "it still states the ceiling it left out")
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
        b.repeat(8) { total.add 1 }              # nothing in the way
        b.repeat(8) { b.call :bump }             # one statement to save the registers around
        b.repeat(8) { 3.times { b.call :bump } } # too many to be worth saving around
      end
    end
    io = StringIO.new
    rom.cost_model.render(rom.source_program, out: io, color: false)

    assert_match(/the loop itself \(in registers\)/, io.string)
    assert_match(/the loop itself \(in registers, saved and put back — the body calls :bump\)/, io.string)
    assert_match(/the loop itself \(through memory — the body calls :bump\)/, io.string)
  end

  # ...and the hottest list splits the two shapes apart, because that is the line a reader
  # reaches for and a hot loop's tree row is often collapsed behind a call. It groups on the
  # shape alone — the reason belongs to one loop, the total to all of them.
  def test_the_hottest_list_counts_the_shapes_apart
    rom = RubyGBA.build("LOOPS", code: "BLPH", maker: "01", err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      total = var :total, 0
      b = self
      func(:bump) { total.add 1 }
      game_loop do
        b.repeat(64) { total.add 1 }
        b.repeat(64) { b.call :bump }
        b.repeat(64) { 3.times { b.call :bump } }
      end
    end
    io = StringIO.new
    rom.cost_model.render(rom.source_program, out: io, color: false)
    hottest = io.string[/hottest[^\n]*:.*/m]

    assert_match(/the loop itself \(in registers\) ×64/, hottest)
    assert_match(/the loop itself \(in registers, saved and put back\) ×64/, hottest)
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

  # THE SECOND ASSUMPTION IN THE BUDGET, and the line has to say which of a pool's two
  # numbers it is talking about: the walk goes round every slot, and the body only runs for
  # the live ones. A reader who took "6 of 64" for the whole story would think a pool with
  # nothing live were free, and it is not.
  def test_the_estimate_says_how_many_of_a_pools_slots_it_took_to_be_live
    io = StringIO.new
    Cost.new.render(pool_walking_game(estimate: { usually: 6 }), out: io)

    assert_match(/a pool walks every slot, and runs its body for the live ones/, io.string)
    assert_match(/:bullet 6 of 64/, io.string, "the number it used, out of the slots there are")
    assert_match(/the number you gave/, io.string, "and that the author is the one who said it")
  end

  # ...and when nobody said, it says that it guessed, and how to answer it.
  def test_a_guessed_live_count_says_so_and_says_how_to_answer_it
    io = StringIO.new
    Cost.new.render(pool_walking_game, out: io)

    assert_match(/:bullet 16 of 64, a guess/, io.string)
    assert_match(/estimate: \{ usually: N \} on the pool/, io.string, "and how to say the real number")
  end

  def test_a_program_with_no_pool_says_nothing_about_one
    io = StringIO.new
    Cost.new.render(program { screen(:bitmap); game_loop { clear_screen :black } }, out: io)

    refute_match(/pool walks/, io.string)
  end

  def pool_walking_game(estimate: nil)
    program do
      screen :bitmap
      bullets = pool :bullet, x: 0, y: 0, capacity: 64, estimate: estimate
      game_loop { bullets.each { |_b| draw_rect_at 0, 0, 8, 8, :green } }
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

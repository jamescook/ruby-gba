# frozen_string_literal: true

require "test_helper"

require_relative "../examples/corridor"

# The corridor example (examples/corridor.rb): the corpus's witness NEAR THE BUDGET.
#
# Every other example is comfortable — before this one the heaviest used under half a frame —
# so the part of the estimate that actually matters, the VERDICT it gives an author, had never
# been asked about a game close to the edge. Corridor spends about four fifths of a frame, and
# the tests below are the two halves of that: it is a real game that draws a real picture, and
# it is heavy enough for the verdict to be worth something.
class TestCorridorExample < Minitest::Test
  include RubyGBA::Constants

  # A frame's worth of scanlines. A game that goes past this tears or slows.
  BUDGET = 228.0

  # RubyGBA.build runs the guardrails and the ROM-image validation, so a clean build IS
  # the check.
  def test_the_example_builds_clean
    assert_operator Corridor.build_rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # It is a first-person view, so a settled frame shows sky above the eye line, floor below it,
  # and walls in between — and the status bar underneath, which is the part `inside` protects.
  def test_it_draws_a_view_with_a_status_bar_under_it
    i = Reference.new.run(Corridor.program, frames: 4)
    pixels = i.screen.to_a

    assert_includes pixels, Corridor::SKY, "sky above the eye line"
    assert_includes pixels, Corridor::FLOOR, "floor below it"
    assert(Corridor::WALL_SHADES.any? { |c| pixels.include?(c) }, "at least one wall column")
    assert_includes pixels, Corridor::BAR, "the status bar under the view"
  end

  # THE STATUS BAR IS NOT DRAWN OVER. `inside` holds the view to the top 128 rows, so nothing
  # the view draws — not the sky, not the floor, not a wall column tall enough to run past the
  # bottom — reaches the bar. Written as a check on the picture rather than on the clip, since
  # the picture is what an author sees.
  def test_the_view_never_reaches_into_the_bar
    i = Reference.new.run(Corridor.program, frames: 4)
    view_colors = [Corridor::SKY, Corridor::FLOOR, *Corridor::WALL_SHADES]

    (Corridor::VIEW_H...160).each do |y|
      row = (0...240).map { |x| i.screen.pixel(x, y) }
      assert_empty(row & view_colors, "row #{y} is under the view and must hold none of its colors")
    end
  end

  # WHAT THE EXAMPLE IS FOR. It has to stay near the budget to be worth having: too light and it
  # is just another comfortable example, too heavy and it tears on the console it ships for. The
  # band is wide because this is a guard against the example drifting out of its job, not a
  # second copy of the corpus accuracy check (rake cost:check owns that).
  def test_it_stays_near_the_budget_without_going_over
    model = Corridor.build_rom.cost_model
    program = Corridor.program
    frame = model.steady_cost(program) + model.standing_costs(program)

    assert_operator frame / BUDGET, :>, 0.5, "a witness near the budget has to be near it"
    assert_operator frame / BUDGET, :<, 1.0, "...and an example that ships must still fit"
  end

  # ...and the same on the console, which is the reading that counts. The estimate above is what
  # the model believes; this is what the hardware does.
  def test_the_console_agrees_it_is_heavy_and_fits
    require_gemba_core!
    measured, = console(Corridor::GAME)

    assert_operator measured / BUDGET, :>, 0.6, "the console should find it heavy: #{measured}"
    assert_operator measured, :<, BUDGET, "...and still inside a frame: #{measured}"
  end

  # THE TEST THIS EXAMPLE EXISTS FOR. Everything above asks whether the NUMBER is close. This
  # asks the only question an author acts on: does it fit? Before corridor nothing in the corpus
  # came within half a frame of the line, so the model had never once been asked to say no —
  # and a check nothing can fail is a check nothing has passed.
  #
  # The same game either side of it: sixty rays fits, eighty does not. The console is the judge
  # and the estimate has to agree with it both times.
  def test_the_estimate_calls_which_side_of_the_line_the_game_is_on
    require_gemba_core!
    [[Corridor::NUM_COLS, Corridor::COL_W, true, "BCOR"],
     [80, 3, false, "BCO8"]].each do |cols, col_w, should_fit, code|
      game = Corridor.game(name: "COR#{cols}", code: code, cols: cols, col_w: col_w)
      measured, = console(game)
      estimate = estimate_of(game)

      assert_equal should_fit, measured < BUDGET,
                   "#{cols} rays: the console measured #{measured.round(1)} of #{BUDGET.to_i}"
      assert_equal should_fit, estimate < BUDGET,
                   "#{cols} rays: the estimate said #{estimate.round(1)}, the console #{measured.round(1)}"
    end
  end

  # PRICE THE PROGRAM THE BUILD ACTUALLY LOWERED, not the one the game block describes. The
  # model charges a statement by what its lowering emitted and finds that by node identity, so
  # handing it a freshly built tree loses every counted statement and reads several per cent
  # light — enough, measured while writing this, to move a verdict.
  def estimate_of(game)
    rom = game.build_rom(out: StringIO.new, err: StringIO.new)
    program = rom.source_program
    model = rom.cost_model
    (model.steady_cost(program) + model.standing_costs(program)).to_f
  end

  # What the console really spends on a pass. A frame it cannot hold reads as the whole frame
  # and no more, so the reading saturates and how long the pass took is asked for separately —
  # the same signal tools/cost_accuracy.rb scores the corpus by.
  def console(game)
    rom = game.build_rom(out: StringIO.new, err: StringIO.new)
    reading = RubyGBA::Analyzer.profile(rom.source_program, options: rom.build_options)
                               .values.max_by(&:scanlines)
    refute_nil reading, "the emulator should give a reading"
    return [reading.per_pass.to_f, true] if reading.saturated?

    [(reading.typical || reading.scanlines).to_f, false]
  end
end

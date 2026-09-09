# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../tools/cost_ranking"

# The order check (tools/cost_ranking.rb): does the report point at the right line? Scored by
# taking a line away and measuring what the frame saved.
#
# Taking the readings needs a build and an emulator run per ablated line, so what is pinned
# here is the rest: which lines are chosen, that a line really comes out of the program, and
# what the score says about the deltas once they are in hand.
class TestCostRanking < Minitest::Test
  Ablation = CostRanking::Ablation
  Score = CostRanking::Score

  def ablation(line, estimated:, measured:)
    Ablation.new(line: line, estimated: estimated, measured: measured)
  end

  def rendered(scores)
    io = StringIO.new
    CostRanking.report(scores, out: io)
    io.string
  end

  # --- the score ---

  # THE FAILURE THIS EXISTS FOR. A total can be exact while two lines are the wrong way round,
  # and the wrong way round is what sends a reader to optimise the wrong thing.
  def test_a_dearest_line_the_console_disagrees_with_is_called_out
    score = Score.new(name: "sprite_mover", figure: :frame, ablations: [
                        ablation("a.rb:1", estimated: 2.0, measured: 0.7),
                        ablation("a.rb:2", estimated: 1.0, measured: 0.9),
                      ])

    refute score.top_agrees?
    assert_match(/THE DEAREST LINE IS NOT THE DEAREST/, rendered([score]))
    assert_match(/Pointing at the wrong line: sprite_mover/, rendered([score]))
  end

  def test_an_order_the_console_agrees_with_scores_one
    score = Score.new(name: "pong", figure: :frame, ablations: [
                        ablation("a.rb:1", estimated: 3.0, measured: 2.8),
                        ablation("a.rb:2", estimated: 2.0, measured: 2.1),
                        ablation("a.rb:3", estimated: 1.0, measured: 0.5),
                      ])

    assert score.top_agrees?
    assert_in_delta 1.0, score.agreement
    assert_match(/dearest on the console/, rendered([score]))
  end

  def test_the_reverse_order_scores_minus_one
    score = Score.new(name: "x", figure: :frame, ablations: [
                        ablation("a.rb:1", estimated: 3.0, measured: 0.5),
                        ablation("a.rb:2", estimated: 2.0, measured: 2.1),
                        ablation("a.rb:3", estimated: 1.0, measured: 2.8),
                      ])

    assert_in_delta(-1.0, score.agreement)
  end

  # A measured saving smaller than the measurement's own wobble is not an order, and counting
  # it would be counting noise.
  def test_a_saving_under_the_noise_is_shown_but_not_ranked
    score = Score.new(name: "x", figure: :frame, ablations: [
                        ablation("a.rb:1", estimated: 3.0, measured: 2.0),
                        ablation("a.rb:2", estimated: 2.0, measured: 1.0),
                        ablation("a.rb:3", estimated: 1.0, measured: CostRanking::NOISE / 2),
                      ])

    assert_equal 2, score.rankable.length
    assert_match(/a\.rb:3.*under the noise, not ranked/, rendered([score]))
  end

  def test_fewer_than_two_ranked_lines_is_no_order_to_score
    score = Score.new(name: "x", figure: :frame, ablations: [
                        ablation("a.rb:1", estimated: 3.0, measured: 2.0),
                        ablation("a.rb:2", estimated: 2.0, measured: 0.01),
                      ])

    refute score.scorable?
    assert_nil score.agreement
    assert_match(/no order to score/, rendered([score]))
  end

  # Which figure the deltas are of is said on every example, because per-pass and per-frame
  # deltas do not mean the same thing (see the file comment on the cliff).
  def test_the_report_says_which_figure_was_differenced
    score = Score.new(name: "raycaster", figure: :pass, ablations: [
                        ablation("a.rb:1", estimated: 3.0, measured: 2.0),
                        ablation("a.rb:2", estimated: 2.0, measured: 1.0),
                      ])

    assert_match(/raycaster \(per pass\)/, rendered([score]))
  end

  def test_the_summary_counts_how_often_the_estimate_points_right
    agrees = Score.new(name: "a", figure: :frame, ablations: [
                         ablation("a.rb:1", estimated: 3.0, measured: 2.0),
                         ablation("a.rb:2", estimated: 2.0, measured: 1.0),
                       ])
    disagrees = Score.new(name: "b", figure: :frame, ablations: [
                            ablation("b.rb:1", estimated: 3.0, measured: 1.0),
                            ablation("b.rb:2", estimated: 2.0, measured: 2.0),
                          ])
    unscored = Score.new(name: "c", note: "no game loop, so nothing recurs")

    out = rendered([agrees, disagrees, unscored])
    assert_match(/dearest line is the console's on 1 of 2 examples/, out)
    assert_match(/c\n  no game loop/, out)
  end

  # --- picking and removing a line ---

  def two_fills
    RubyGBA.build("ABLATE", code: "BABL", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      game_loop do
        fill_rect 0, 0, 240, 40, :red
        fill_rect 0, 0, 8, 8, :blue
      end
    end
  end

  # The candidates are the tree's own ranking, dearest first — the same weighing the hottest
  # list uses, summed by the line the work came from. The game loop's own line is not one:
  # taking it away takes the frame away.
  def test_the_candidates_are_the_dearest_lines_first_and_never_the_loop_itself
    rom = two_fills
    lines = CostRanking.candidate_lines(rom.cost_model, rom.source_program)
    big, small = rom.source_program.each.select { |n| n.kind == :fill_rect }.map(&:source)

    assert_equal [big, small], lines
  end

  # ...and the ones measured are those that save the most EVERY frame, which is what the
  # console's reading is of. A line a normal frame never reaches saves nothing on paper and is
  # not worth an emulator run.
  def test_the_lines_chosen_are_the_ones_that_save_the_most_every_frame
    rom = two_fills
    program = rom.source_program
    base = CostRanking.every_frame(rom.cost_model, program)
    big, small = program.each.select { |n| n.kind == :fill_rect }.map(&:source)

    chosen = CostRanking.chosen_lines(program, rom.build_options, base, [small, big])

    assert_equal [big, small], chosen.map(&:first)
    assert_operator chosen.first.last, :>, chosen.last.last, "the estimated saving rides along, dearest first"
  end

  # Taking a line away removes what was written on it and nothing else, and leaves the
  # program it was taken from untouched.
  def test_taking_a_line_away_removes_exactly_that_statement
    program = two_fills.source_program
    big, small = program.each.select { |n| n.kind == :fill_rect }
    before = program.each.count

    variant = CostRanking.without(program, big.source)

    assert_equal before - 1, variant.each.count
    assert_equal [small.source], variant.each.select { |n| n.kind == :fill_rect }.map(&:source)
    assert_equal before, program.each.count, "the original is not the one edited"
  end

  def test_a_line_no_statement_carries_cannot_be_taken_away
    assert_nil CostRanking.without(two_fills.source_program, "nowhere.rb:1")
  end
end

# frozen_string_literal: true

require "test_helper"

# The budget-threshold guardrail: when a game draws a growing list item by item
# every frame, warn with the count at which it tips over the frame budget — and the
# list's declared cap, so the author can cap it lower. Advisory, never an error.
# It only speaks when the tip-over is reachable within the cap (capping lower would
# bring the frame back under); a loop that fits even full stays quiet.
class TestBudgetThresholdGuardrail < Minitest::Test
  Check = RubyGBA::IR::Guardrails::Checks::BudgetThreshold
  Cost = RubyGBA::IR::CostModel

  def build_program(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A big per-item draw over a large list: over budget well before the list fills.
  def growing_draw_game(cap:, cell:)
    build_program do
      screen :bitmap
      swarm = list :swarm, capacity: cap
      game_loop do
        wait_vblank
        repeat(swarm.length) { |_i| draw_rect_at 0, 0, cell, cell, :red }
      end
    end
  end

  def test_a_growing_draw_loop_warns_with_the_tip_over_count
    findings = Check.new.detect(growing_draw_game(cap: 64, cell: 20))
    assert_equal 1, findings.length
    assert findings.first.warning?, "the threshold is advisory, not a hard error"
    assert_match(/swarm/, findings.first.message)          # names the list to cap
    assert_match(/over budget/, findings.first.message)
  end

  # The analysis itself: the tip-over count is within the cap (so it's reachable).
  def test_the_break_even_count_is_below_the_cap
    threshold = Cost.new.budget_thresholds(growing_draw_game(cap: 64, cell: 20)).first
    refute_nil threshold
    assert_equal :swarm, threshold[:list]
    assert_equal 64, threshold[:cap]
    assert_operator threshold[:break_even], :>=, 0
    assert_operator threshold[:break_even], :<, threshold[:cap]
  end

  # A small per-item draw that fits even at full capacity says nothing.
  def test_a_loop_that_fits_even_full_is_quiet
    assert_empty Check.new.detect(growing_draw_game(cap: 8, cell: 2))
  end

  # No growing loop, nothing to warn about.
  def test_a_game_without_a_growing_loop_is_quiet
    prog = build_program do
      screen :bitmap
      game_loop { wait_vblank; clear_screen :black }
    end
    assert_empty Check.new.detect(prog)
  end

  # The finding points at the exact DSL line the loop was written on — built through
  # the DSL so the node carries its call site (compared against the node's own source
  # rather than a hard-coded line, so it survives edits to this file).
  def test_a_finding_cites_the_dsl_source_line
    prog = growing_draw_game(cap: 64, cell: 20)
    loop_node = prog.walk.find { |node| node.kind == :repeat }

    refute_nil loop_node.source, "the loop node should carry its DSL call site"
    assert_match(/test_.*\.rb:\d+/, loop_node.source)

    finding = Check.new.detect(prog).first
    assert_equal loop_node.source, finding.source, "the finding carries the loop's source"
    # The location is appended automatically by the framework, not baked into the message.
    assert_includes finding.full_message, loop_node.source
    refute_includes finding.message, loop_node.source, "the raw message stays location-free"
  end

  # It's a builtin: it fires in the default validation pass.
  def test_it_runs_in_the_default_validation_pass
    report = RubyGBA::IR::Guardrails::Validator.new.run(growing_draw_game(cap: 64, cell: 20), autofix: false)
    assert(report.warnings.any? { |w| w.check == :budget_threshold },
           "the budget-threshold guardrail should be registered as a builtin")
  end
end

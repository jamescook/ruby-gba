# frozen_string_literal: true

require "test_helper"

# The budget-threshold guardrail: when a game draws a growing list item by item
# every frame, warn with the count at which it tips over the frame budget — and the
# list's declared cap, so the author can cap it lower. Advisory, never an error.
# It only speaks when the tip-over is reachable within the cap (capping lower would
# bring the frame back under); a loop that fits even full stays quiet.
class TestBudgetThresholdGuardrail < Minitest::Test
  Check = RubyGBA::IR::Guardrails::Checks::BudgetThreshold

  # The check is handed a cost model, since the tip-over count depends on how the build
  # turned out. A model with no build behind it prices pessimistically, which is what these
  # tests use; a real build hands over its own (Guardrails.build_checks).
  def check = Check.new(RubyGBA::IR::CostModel.new)
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
    findings = check.detect(growing_draw_game(cap: 64, cell: 20))
    assert_equal 1, findings.length
    assert findings.first.warning?, "the threshold is advisory, not a hard error"
    assert_match(/swarm/, findings.first.message)          # names the list to cap
    assert_match(/over budget/, findings.first.message)
  end

  # The analysis itself: the tip-over count is within the cap (so it's reachable).
  def test_the_break_even_count_is_below_the_cap
    threshold = Cost.new.budget_thresholds(growing_draw_game(cap: 64, cell: 20)).first
    refute_nil threshold
    assert_equal :swarm, threshold.list
    assert_equal 64, threshold.cap
    assert_operator threshold.break_even, :>=, 0
    assert_operator threshold.break_even, :<, threshold.cap
  end

  # A small per-item draw that fits even at full capacity says nothing.
  def test_a_loop_that_fits_even_full_is_quiet
    assert_empty check.detect(growing_draw_game(cap: 8, cell: 2))
  end

  # NOR DOES A LENGTH THE LIST CANNOT REACH. A list's storage is a ring, and a ring wraps an
  # index with a mask, so its size is rounded up to a power of two — 33 items get 64 slots.
  # Those spare slots are for the mask, not for the game: the author said 33. A frame that
  # only gives out at 41 gives out at a length this list is never going to hold, and saying
  # so is crying wolf. (The same shape at 64 warns, two tests up: there 41 is reachable.)
  def test_a_tip_over_in_the_rounded_up_headroom_is_quiet
    assert_empty check.detect(growing_draw_game(cap: 33, cell: 20))
  end

  # ...and the same list DOES warn once the body is dear enough to give out inside the length
  # the author asked for. So it is the declared length that decides, not the rounding.
  def test_the_same_list_warns_when_the_tip_over_is_inside_what_was_declared
    threshold = Cost.new.budget_thresholds(growing_draw_game(cap: 33, cell: 30)).first

    refute_nil threshold
    assert_equal 33, threshold.cap, "the length the author asked for, not the 64 slots it got"
    assert_operator threshold.break_even, :<, 33
  end

  # A POOL BESIDE THE LIST IS HELD FULL WHILE THIS QUESTION IS ASKED, and it has to be. The
  # every-frame figure counts a pool's body for the slots usually live, which is right for
  # "what does this frame cost" and wrong for this one: the list's tip-over is solved against
  # the REST of the frame, and the rest of a frame that has given out is a full one. Discount
  # the pool here and the list gets told it has more room than it has.
  def test_a_pool_beside_a_growing_list_is_counted_full_while_the_list_is_solved
    quiet = Cost.new.budget_thresholds(pool_and_list_game(usually: 1)).first
    busy = Cost.new.budget_thresholds(pool_and_list_game(usually: 32)).first
    alone = Cost.new.budget_thresholds(growing_draw_game(cap: 64, cell: 20)).first

    refute_nil quiet, "the list still tips over"
    assert_equal busy.break_even, quiet.break_even,
                 "what the pool usually holds cannot move the length at which the list gives out"
    assert_operator quiet.break_even, :<, alone.break_even - 20,
                    "a frame already full of pool bodies leaves the list far less room"
  end

  # The same growing list, with a pool of equally dear bodies beside it.
  def pool_and_list_game(usually:)
    build_program do
      screen :bitmap
      swarm = list :swarm, capacity: 64
      shots = pool :shot, x: 0, y: 0, capacity: 32, estimate: { usually: usually }
      game_loop do
        wait_vblank
        shots.each { |_s| draw_rect_at 0, 0, 20, 20, :blue }
        repeat(swarm.length) { |_i| draw_rect_at 0, 0, 20, 20, :red }
      end
    end
  end

  # No growing loop, nothing to warn about.
  def test_a_game_without_a_growing_loop_is_quiet
    prog = build_program do
      screen :bitmap
      game_loop { wait_vblank; clear_screen :black }
    end
    assert_empty check.detect(prog)
  end

  # The finding points at the exact DSL line the loop was written on — built through
  # the DSL so the node carries its call site (compared against the node's own source
  # rather than a hard-coded line, so it survives edits to this file).
  def test_a_finding_cites_the_dsl_source_line
    prog = growing_draw_game(cap: 64, cell: 20)
    loop_node = prog.walk.find { |node| node.kind == :repeat }

    refute_nil loop_node.source, "the loop node should carry its DSL call site"
    assert_match(/test_.*\.rb:\d+/, loop_node.source)

    finding = check.detect(prog).first
    assert_equal loop_node.source, finding.source, "the finding carries the loop's source"
    # The location is appended automatically by the framework, not baked into the message.
    assert_includes finding.full_message, loop_node.source
    refute_includes finding.message, loop_node.source, "the raw message stays location-free"
  end

  # It fires in a real build, in the pass that runs after lowering — where the tip-over
  # count is worked out from what the build actually decided rather than from defaults.
  def test_it_runs_in_a_real_build
    err = StringIO.new
    RubyGBA.build("THRESHOLD", code: "ZTHR", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      swarm = list :swarm, capacity: 256
      game_loop do
        repeat(swarm.length) { |_i| draw_rect_at 0, 0, 20, 20, :red }
      end
    end

    assert_match(/swarm/, err.string, "a growing draw loop should warn during the build")
    assert_match(/over budget/, err.string)
  end

  # THE NUMBER COMES FROM THE BUILD, which is the whole point of running this check after
  # lowering. Priced with no build behind it, a loop is charged as though its counter went
  # through memory and nothing was kept in the console's quick memory — every default is the
  # dearer guess — so the count it names is far too small. Held as an inequality rather than
  # against a figure, because the figures move whenever the lowering does; what must not
  # move is which side of the other each one falls.
  def test_the_tip_over_count_is_the_builds_answer_not_the_pessimistic_one
    program = growing_draw_game(cap: 256, cell: 20)
    rom = RubyGBA.build("THRESHOLD", code: "ZTHR", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      swarm = list :swarm, capacity: 256
      game_loop do
        repeat(swarm.length) { |_i| draw_rect_at 0, 0, 20, 20, :red }
      end
    end

    pessimistic = Cost.new.budget_thresholds(program).first.break_even
    built = rom.cost_model.budget_thresholds(program).first.break_even

    assert_operator built, :>, pessimistic * 2,
                    "a frame priced with the build's own answers fits far more items than one priced without"
  end
end

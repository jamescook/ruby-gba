# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"

# The whole-program IWRAM budget guardrail. Every variable, list, and component pool
# lives in the GBA's 32KB of fast RAM; the allocator never checks the ceiling, so a
# program that reserves past it silently overruns into a black-screen ROM. This check
# sums what the program reserves and, if it's over the usable budget, stops the build
# with a friendly error naming the total, the budget, and the biggest users. A program
# within budget is untouched.
class TestIRGuardrailIwramBudget < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails
  Budget = Guardrails::Checks::IwramBudget

  def validator
    Guardrails::Validator.new(checks: [Budget.new])
  end

  def findings_for(program)
    validator.run(program, autofix: false).findings
  end

  # A list whose capacity, in words, is at least +bytes+ of storage — a blunt way to
  # reserve a known amount of IWRAM in a test.
  def list_of_bytes(name, bytes)
    list_new(name, bytes / Budget::WORD)
  end

  def test_a_program_within_budget_is_not_flagged
    prog = program(
      screen(:bitmap),
      list_new(:trail, 64),
      set(:score, int(0)),
      loop_(wait_vblank, list_push(:trail, int(1)), halt),
    )
    assert_empty findings_for(prog)
  end

  def test_an_over_budget_program_is_a_fatal_error
    prog = program(
      screen(:bitmap),
      list_of_bytes(:huge, Budget::BUDGET_BYTES + 4 * 1024),
      loop_(wait_vblank, halt),
    )
    findings = findings_for(prog)
    assert_equal 1, findings.size
    assert findings.first.error?, "over-budget IWRAM would break the ROM, so it's fatal, not advisory"
    assert_equal :huge, findings.first.node[:name],
                 "it blames the biggest user — the declaration whose capacity has to shrink"
  end

  # The message names the total, the budget, and the largest contributor by its
  # friendly name — enough for the fix to be obvious.
  def test_the_error_names_the_total_the_budget_and_the_offender
    prog = program(
      screen(:bitmap),
      list_of_bytes(:trail, Budget::BUDGET_BYTES + 8 * 1024),
      loop_(wait_vblank, halt),
    )
    message = findings_for(prog).first.message
    assert_match(/list :trail/, message)         # the offender, by name
    assert_match(/32KB/, message)                # the hardware total
    assert_match(/#{Budget::BUDGET_BYTES / 1024}KB/, message) # the usable budget
    assert_match(/fast RAM/i, message)
  end

  # A pool's several backing lists collapse into one "pool :name" contributor — the
  # author declared one pool, not five lists.
  def test_a_pool_is_named_as_one_contributor
    # Emulate a pool's storage: field lists + active + free, all __pool_<name>_*.
    big = (Budget::BUDGET_BYTES + 8 * 1024) / (3 * Budget::WORD) # split across three lists
    prog = program(
      screen(:tiled),
      list_new(:__pool_enemy_x, big),
      list_new(:__pool_enemy_y, big),
      list_new(:__pool_enemy_active, big),
      loop_(wait_vblank, halt),
    )
    message = findings_for(prog).first.message
    assert_match(/pool :enemy/, message)
    refute_match(/__pool_enemy/, message) # the raw storage names never leak to the person
  end

  # Two ordinary allocations that each fit can add up to an overflow — the whole-program
  # check's reason to exist (each alone would pass a per-item ceiling).
  def test_two_within_reach_allocations_can_overflow_together
    half = Budget::BUDGET_BYTES / 2
    each_ok = program(screen(:bitmap), list_of_bytes(:a, half - 2 * 1024), loop_(wait_vblank, halt))
    assert_empty findings_for(each_ok), "one half-budget list is fine on its own"

    both = program(
      screen(:bitmap),
      list_of_bytes(:a, half),
      list_of_bytes(:b, half),
      loop_(wait_vblank, halt),
    )
    findings = findings_for(both)
    assert_equal 1, findings.size, "but two together tip over the budget"
    assert_match(/list :a/, findings.first.message)
    assert_match(/list :b/, findings.first.message)
  end

  # End to end through the DSL: an over-budget program stops the build with the
  # friendly error on the err stream (a fatal guardrail raises ROMError).
  def test_the_build_stops_on_an_over_budget_program
    err = StringIO.new
    error = assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("BIG", code: "BBIG", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        list :trail, capacity: 12_000 # ~48KB of slots, well over the budget
        game_loop { wait_vblank }
      end
    end
    assert_match(/problem/i, error.message)
    assert_match(/fast RAM/i, err.string)
    assert_match(/list :trail/, err.string)
  end

  # A realistic-sized program builds unaffected — the guardrail only speaks on genuine
  # overflow, never on an ordinary game's handful of vars, lists, and a pool.
  def test_a_realistic_program_builds_unaffected
    err = StringIO.new
    RubyGBA.build("GAME", code: "BGME", maker: "01", out: StringIO.new, err: err) do
      screen :tiled
      image(:ufo, "#" => :green) { "########\n" * 8 }
      enemies = pool :enemy, x: 0, y: 0, hp: 3, capacity: 32, image: :ufo
      var :score, 0
      list :shots, capacity: 16
      game_loop do
        wait_vblank
        enemies.each { |e| e.y.add 1 }
      end
    end
    refute_match(/fast RAM/i, err.string, "an ordinary game is nowhere near the budget")
  end
end

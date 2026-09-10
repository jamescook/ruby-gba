# frozen_string_literal: true

require "test_helper"

require "stringio"

# WHAT A PROGRAM RESERVES, against the memory there really is.
#
# The console has two work memories: 32K of quick on-chip RAM and 256K of roomier RAM on a
# chip of its own. A collection can live in either — the framework puts what a frame touches
# in the quick one and lets the rest fall into the roomy one — so a program with a lot of
# state is no longer a build failure just because it will not all fit near to hand. That is
# what this check used to say, and it was the wrong thing to say.
#
# What it still says is the part that is really a ceiling. A VARIABLE cannot move: it is
# reached by its distance from the start of the quick memory, which is what makes a read two
# instructions instead of four. And everything together still has to fit in the two memories
# added up.
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
  # reserve a known amount of memory in a test.
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

  # THE ONE THIS BEAD CHANGED. A list past the quick memory used to stop the build. It
  # moves now, and moving is not something to report as a problem.
  def test_a_list_past_the_quick_memory_is_no_longer_a_problem
    prog = program(
      screen(:bitmap),
      list_of_bytes(:huge, Budget::BUDGET_BYTES + (8 * 1024)),
      loop_(wait_vblank, halt),
    )
    assert_empty findings_for(prog), "it goes in the roomier memory instead"
  end

  def test_past_both_memories_is_a_fatal_error
    prog = program(
      screen(:bitmap),
      list_of_bytes(:huge, Budget::BUDGET_BYTES + Budget::EWRAM_BYTES + (8 * 1024)),
      loop_(wait_vblank, halt),
    )
    findings = findings_for(prog)
    assert_equal 1, findings.size
    assert findings.first.error?, "past every memory there is would break the ROM"
    assert_equal :huge, findings.first.node.name,
                 "it blames the biggest user — the declaration whose capacity has to shrink"
  end

  def test_the_error_names_the_total_the_memories_and_the_offender
    prog = program(
      screen(:bitmap),
      list_of_bytes(:trail, Budget::BUDGET_BYTES + Budget::EWRAM_BYTES + (8 * 1024)),
      loop_(wait_vblank, halt),
    )
    message = findings_for(prog).first.message
    assert_match(/list :trail/, message)                          # the offender, by name
    assert_match(/32KB/, message)                                 # the quick memory
    assert_match(/256KB/, message)                                # ...and the roomy one
    assert_match(/#{RubyGBA::PlainWords::QUICK_MEMORY}/, message) # said the one way it is said
  end

  # VARIABLES CANNOT MOVE, so they have their own ceiling and their own explanation. A
  # program whose variables alone fill the quick memory cannot be helped by the other one.
  def test_more_variables_than_the_quick_memory_holds_is_a_fatal_error
    count = (Budget::BUDGET_BYTES / Budget::WORD) + 512
    prog = program(
      screen(:bitmap),
      *count.times.map { |i| set(:"v#{i}", int(0)) },
      loop_(wait_vblank, halt),
    )
    findings = findings_for(prog)
    assert_equal 1, findings.size
    message = findings.first.message
    assert_match(/variable/, message, "it names what is filling the memory")
    assert_match(/cannot/, message, "and says why those cannot move like a list can")
    assert_match(/list/, message, "and what to do instead")
  end

  # A pool's several backing lists collapse into one "pool :name" contributor — the
  # author declared one pool, not five lists.
  def test_a_pool_is_named_as_one_contributor
    # Emulate a pool's storage: field lists + active + free, all __pool_<name>_*.
    over = Budget::BUDGET_BYTES + Budget::EWRAM_BYTES + (8 * 1024)
    big = over / (3 * Budget::WORD) # split across three lists
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

  # End to end through the DSL: a program past every memory there is stops the build with
  # the friendly error on the err stream (a fatal guardrail raises ROMError).
  def test_the_build_stops_on_a_program_past_every_memory
    err = StringIO.new
    error = assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("BIG", code: "BBIG", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        list :trail, capacity: 100_000 # ~400KB of slots, past both memories together
        game_loop { wait_vblank }
      end
    end
    assert_match(/problem/i, error.message)
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
    refute_match(/#{RubyGBA::PlainWords::QUICK_MEMORY}/, err.string,
                 "an ordinary game is nowhere near the budget")
  end
end

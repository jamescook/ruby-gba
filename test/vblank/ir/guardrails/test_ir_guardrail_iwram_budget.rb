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
  include VBlank::IR::Build

  Guardrails = VBlank::IR::Guardrails
  Budget = Guardrails::Checks::IwramBudget

  # The Advance's memory, which a program that names no console is checked against: the quick
  # memory free for the game once the build has kept its part, and the roomier one beside it.
  ADVANCE = VBlank::Console::ADVANCE
  QUICK_FREE = ADVANCE.free_work_memory_bytes
  ROOMIER = ADVANCE.roomier_memory_bytes

  private def validator
    Guardrails::Validator.new(checks: [Budget.new])
  end

  private def findings_for(program)
    validator.run(program, autofix: false).findings
  end

  # A list whose capacity, in words, is at least +bytes+ of storage — a blunt way to
  # reserve a known amount of memory in a test.
  private def list_of_bytes(name, bytes)
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
      list_of_bytes(:huge, QUICK_FREE + (8 * 1024)),
      loop_(wait_vblank, halt),
    )
    assert_empty findings_for(prog), "it goes in the roomier memory instead"
  end

  def test_past_both_memories_is_a_fatal_error
    prog = program(
      screen(:bitmap),
      list_of_bytes(:huge, QUICK_FREE + ROOMIER + (8 * 1024)),
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
      list_of_bytes(:trail, QUICK_FREE + ROOMIER + (8 * 1024)),
      loop_(wait_vblank, halt),
    )
    message = findings_for(prog).first.message
    assert_match(/list :trail/, message)                          # the offender, by name
    assert_match(/32KB/, message)                                 # the quick memory
    assert_match(/256KB/, message)                                # ...and the roomy one
    assert_match(/#{VBlank::Messages::PlainWords::QUICK_MEMORY}/, message) # said the one way it is said
  end

  # VARIABLES CANNOT MOVE, so they have their own ceiling and their own explanation. A
  # program whose variables alone fill the quick memory cannot be helped by the other one.
  def test_more_variables_than_the_quick_memory_holds_is_a_fatal_error
    count = (QUICK_FREE / Budget::WORD) + 512
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
    # Emulate a pool's storage: two field lists and the list of which slots are live. The
    # field has an underscore in it, which must not be read as part of the pool's name.
    over = QUICK_FREE + ROOMIER + (8 * 1024)
    big = over / (3 * Budget::WORD) # split across three lists
    pool = VBlank::DSL::Pool
    prog = program(
      screen(:tiled),
      list_new(pool.field_list(:enemy, :x), big),
      list_new(pool.field_list(:enemy, :walk_timer), big),
      list_new(pool.active_list(:enemy), big),
      loop_(wait_vblank, halt),
    )
    message = findings_for(prog).first.message
    assert_match(/pool :enemy\b/, message)
    refute_match(/pool :enemy_walk/, message)
    refute_match(/__pool/, message) # the raw storage names never leak to the person
  end

  # A save_data record keeps lists of its own under names the build made up — the biggest a
  # buffer as big as what it keeps, twice over. The author wrote `save_data :file`, so that is
  # who is named, and the fix said is one the author can do: a record has no capacity to shrink.
  def test_a_save_records_lists_are_named_as_the_record
    stage = VBlank::Messages::MadeNames.make(:save_record, record: "file", piece: "stage")
    prog = program(
      screen(:bitmap),
      list_of_bytes(stage, QUICK_FREE + ROOMIER + (8 * 1024)),
      loop_(wait_vblank, halt),
    )
    message = findings_for(prog).first.message
    assert_match(/save_data :file/, message)
    refute_match(/__save/, message)
    assert_match(/keep fewer variables and lists in it/, message)
  end

  # End to end through the DSL: a program past every memory there is stops the build with
  # the friendly error on the err stream (a fatal guardrail raises ROMError).
  def test_the_build_stops_on_a_program_past_every_memory
    err = StringIO.new
    error = assert_raises(VBlank::ROMError) do
      VBlank.build("BIG", console: :gba, code: "BBIG", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        list :trail, capacity: 100_000 # ~400KB of slots, past both memories together
        game_loop { wait_vblank }
      end
    end
    assert_match(/problem/i, error.message)
    assert_match(/list :trail/, err.string)
  end

  # A GAME FOR THE COLOR IS CHECKED AGAINST THE COLOR'S MEMORY: 8K, every variable and list in
  # it, and no roomier memory beside it. A list the Advance would hold without a word is too big.
  def test_a_color_program_past_the_colors_memory_is_a_fatal_error
    prog = program(
      screen(:tiled),
      list_of_bytes(:trail, 9 * 1024),
      loop_(wait_vblank, halt),
      console: :gbc,
    )
    findings = findings_for(prog)
    assert_equal 1, findings.size
    assert findings.first.error?
    message = findings.first.message
    assert_match(/list :trail/, message)
    assert_match(/Game Boy Color/, message)
    assert_match(/8KB/, message)
    refute_match(/256KB/, message, "the Advance's roomier memory is not the Color's")
  end

  # On the Color variables share the one memory with the lists, so fewer of them is a fix too.
  def test_a_color_program_with_too_many_variables_is_told_to_use_fewer
    count = (VBlank::Console::COLOR.free_work_memory_bytes / Budget::WORD) + 64
    prog = program(
      screen(:tiled),
      *Array.new(count) { |i| set(:"v#{i}", int(0)) },
      loop_(wait_vblank, halt),
      console: :gbc,
    )
    message = findings_for(prog).first.message
    assert_match(/variables/, message, "it names what is filling the memory")
    assert_match(/fewer variables/, message)
  end

  def test_a_color_program_within_the_colors_memory_is_not_flagged
    prog = program(
      screen(:tiled),
      list_of_bytes(:trail, 2 * 1024),
      loop_(wait_vblank, halt),
      console: :gbc,
    )
    assert_empty findings_for(prog)
  end

  # End to end: the Color's build stops on the check, before its cartridge is laid out.
  def test_the_color_build_stops_on_a_program_past_its_memory
    err = StringIO.new
    assert_raises(VBlank::ROMError) do
      VBlank.build("BIGGBC", console: :gbc, out: StringIO.new, err: err) do
        screen :bitmap
        list :trail, capacity: 4000 # about 16KB of slots, twice what the Color has
        game_loop { pixel 0, 0, :red }
      end
    end
    assert_match(/list :trail/, err.string)
    assert_match(/Game Boy Color/, err.string)
  end

  # A realistic-sized program builds unaffected — the guardrail only speaks on genuine
  # overflow, never on an ordinary game's handful of vars, lists, and a pool.
  def test_a_realistic_program_builds_unaffected
    err = StringIO.new
    VBlank.build("GAME", console: :gba, code: "BGME", maker: "01", out: StringIO.new, err: err) do
      screen :tiled
      image(:ufo, "#" => :green) { "########\n" * 8 }
      enemies = pool :enemy, x: 0, y: 0, hp: 3, capacity: 32, image: :ufo
      var :score, 0
      list :shots, capacity: 16
      game_loop do
        wait_vblank
        enemies.each { |e| e.y.add! 1 }
      end
    end
    refute_match(/#{VBlank::Messages::PlainWords::QUICK_MEMORY}/, err.string,
                 "an ordinary game is nowhere near the budget")
  end
end

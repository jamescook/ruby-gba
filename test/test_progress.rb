# frozen_string_literal: true

require "test_helper"

require "stringio"

# WHAT A BUILD SAYS IT IS DOING (lib/ruby_gba/progress.rb).
#
# A big game takes a while to build, and a build that says nothing is indistinguishable from one
# that has hung. These check the thing a build talks to: that the default says nothing at all,
# that one pointed at a stream says the phases in order with what each took, and that a phase
# reporting tens of thousands of times does not turn into tens of thousands of lines.
class TestProgress < Minitest::Test
  Progress = RubyGBA::Progress

  # A clock that only moves when a test moves it, so an elapsed time is a fact rather than a
  # race. It answers the one question Progress asks of a clock.
  class FakeClock
    def initialize = @now = 0.0
    def clock_gettime(_kind) = @now
    def pass(seconds) = @now += seconds
  end

  def a_terminal
    out = StringIO.new
    def out.tty? = true
    out
  end

  # A log's phase lines, split back into their columns: the phase, how long it took, and where
  # it got to (which is the rest of the line, and may be nothing at all).
  Phase = Data.define(:name, :took, :where)

  def phases_in(out)
    out.string.lines.map do |line|
      name, took, *where = line.strip.split(/\s{2,}/)
      Phase.new(name: name, took: took, where: where.join("  "))
    end
  end

  # A program with enough statements in it to be worth reporting on — a tick only consults the
  # clock every few hundred, so a three-line program never gets as far as saying anything.
  # It has a routine and a frame in it because that is what the phase choosing what goes in the
  # quick memory has to choose BETWEEN — a program of loose statements gives it nothing to rank.
  MANY_STATEMENTS = proc do
    screen :bitmap
    func(:paint) { 300.times { |n| pixel n % 240, n % 160, :red } }
    game_loop { call :paint }
  end

  # Build it while a progress is listening, and hand back its phase lines in columns.
  def phases_of_a_build
    out = StringIO.new
    RubyGBA.build("SPEAK", code: "ASPK", maker: "01", out: StringIO.new, err: StringIO.new,
                          progress: Progress.to(out), &MANY_STATEMENTS)
    phases_in(out)
  end

  # ...keyed by phase, so a test can ask one phase where it got to.
  def where_each_phase_got_to
    phases_of_a_build.to_h { |phase| [phase.name, phase.where] }
  end

  # --- THE ONE THAT SAYS NOTHING ---------------------------------------------------------------

  # It is the DEFAULT, so every method has to be here. A caller asking "is anybody listening?"
  # before every line is forty chances to forget one, and reads as uncertainty about something
  # that is never uncertain.
  def test_the_silent_one_answers_every_method
    quiet = Progress.silent

    assert_nil quiet.step("anything")
    assert_nil quiet.of(1, 2, "anything")
    assert_nil quiet.tick
    assert_nil quiet.done
  end

  def test_the_silent_one_is_what_a_build_gets_unless_it_asks
    err = StringIO.new
    RubyGBA.build("QUIET", code: "AQUI", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      fill_rect 0, 0, 8, 8, :red
      halt
    end

    refute_match(/lowering|the guardrails|checking the tree/, err.string,
                 "a build that did not ask for progress should not talk about itself")
  end

  # --- THE ONE THAT WRITES ---------------------------------------------------------------------

  def test_it_names_each_phase_in_the_order_they_happened
    out = StringIO.new
    progress = Progress::Printed.new(out, clock: FakeClock.new)
    %w[reading checking lowering].each { |phase| progress.step(phase) }
    progress.done

    assert_equal %w[reading checking lowering], out.string.lines.map { |line| line.split.first }
  end

  # A phase's time is written when the phase ENDS, so it is only ever reported once it really
  # has elapsed — which is why starting the next phase is what closes the last.
  def test_each_phase_says_how_long_it_took
    clock = FakeClock.new
    out = StringIO.new
    progress = Progress::Printed.new(out, clock: clock)

    progress.step("reading")
    clock.pass(2.5)
    progress.step("lowering")
    clock.pass(41.0)
    progress.done

    assert_match(/reading\s+2\.5s/, out.string)
    assert_match(/lowering\s+41\.0s/, out.string)
  end

  def test_a_countable_phase_says_where_it_got_to
    out = a_terminal
    progress = Progress::Printed.new(out, clock: FakeClock.new)
    progress.step("the guardrails")
    progress.of(27, 27, "DrawBudget")
    progress.done

    assert_match(/the guardrails.*27 of 27\s+DrawBudget/, out.string)
  end

  # --- A PHASE THAT REPORTS TENS OF THOUSANDS OF TIMES -----------------------------------------

  # THE ONE THAT WOULD COST MORE THAN IT REPORTS. Lowering ticks per instruction; printing that
  # often would be slower than the work being described, so the SINK decides when to draw.
  def test_a_hundred_thousand_ticks_is_not_a_hundred_thousand_lines
    clock = FakeClock.new
    out = a_terminal
    progress = Progress::Printed.new(out, clock: clock)
    progress.step("lowering")
    100_000.times do |n|
      clock.pass(0.001) # a hundred seconds of ticking, in total
      progress.tick
      _ = n
    end
    progress.done

    # A line at most every tenth of a second over a hundred seconds is about a thousand, and
    # the point is only that it is bounded by the CLOCK rather than by the tick count.
    written = out.string.count("\r")

    assert_operator written, :<, 2_000, "the sink should throttle, not print every tick"
    assert_operator written, :>, 100, "...but it should still be showing progress"
  end

  def test_ticking_costs_nothing_worth_measuring_when_nobody_is_listening
    quiet = Progress.silent
    from = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    1_000_000.times { quiet.tick }
    spent = Process.clock_gettime(Process::CLOCK_MONOTONIC) - from

    assert_operator spent, :<, 1.0, "a million ticks into the silent one should be free"
  end

  # ...and a tick carrying a label is free too, which is the whole reason the label comes in a
  # BLOCK. Lowering reports its size in one, once per statement, and a build nobody is watching
  # must never pay for building a string it will not print.
  def test_a_tick_that_carries_a_label_does_not_build_it_when_nobody_is_listening
    quiet = Progress.silent
    built = 0
    1_000_000.times { quiet.tick { built += 1 } }

    assert_equal 0, built
  end

  # --- WHERE IT IS WRITING DECIDES HOW MUCH IT SHOWS -------------------------------------------

  # A log is read afterwards and a carriage return in one is noise, so anywhere but a terminal
  # gets one tidy line per phase and nothing in between.
  def test_a_log_gets_one_line_per_phase_and_no_rewriting
    out = StringIO.new
    progress = Progress::Printed.new(out, clock: FakeClock.new)
    progress.step("lowering")
    500.times { progress.tick }
    progress.done

    assert_equal 1, out.string.lines.length
    refute_includes out.string, "\r"
  end

  # ...and a terminal gets one line kept and rewritten, which is what reads as a build getting
  # on with it rather than a wall of text.
  def test_a_terminal_gets_one_line_kept_and_rewritten
    clock = FakeClock.new
    out = a_terminal
    progress = Progress::Printed.new(out, clock: clock)
    progress.step("lowering")
    3.times do
      clock.pass(1.0)
      progress.of(1, 3)
    end
    progress.done

    assert_includes out.string, "\r"
    assert_equal 1, out.string.lines.length, "a rewritten line is still one line"
  end

  # --- A PHASE THAT IS SAYING NOTHING ----------------------------------------------------------

  # THE ONE THING THE BUILD CANNOT REPORT ITSELF. A phase can spend fifteen seconds inside a
  # single call, and while it is in there it says nothing because it is not running any of our
  # code. A line that is only redrawn when it is told would sit at 0.0s for all of it and read
  # as a hang, so the line keeps its own clock. Uses the real clock, because what is being
  # checked is precisely that time passing is enough.
  def test_the_line_keeps_counting_while_the_build_says_nothing
    out = a_terminal
    progress = Progress.to(out, refresh: 0.01)
    progress.step("a phase that says nothing")
    sleep 0.2 # the build, inside one long call, reporting nothing at all
    progress.done

    assert_operator out.string.count("\r"), :>, 2,
                    "a live line should redraw itself while a phase is open"
  end

  # ...and a log does not, because there is nothing to animate: one line per phase, written when
  # the phase ends.
  def test_a_log_is_not_redrawn_while_a_phase_says_nothing
    out = StringIO.new
    progress = Progress.to(out, refresh: 0.01)
    progress.step("a phase that says nothing")
    sleep 0.1
    progress.done

    assert_equal 1, out.string.lines.length
  end

  # A redraw covers what it replaces. A shorter line drawn over a longer one used to leave the
  # tail of the old one showing, and the tail reads as part of the new line — a phase that took
  # 4.5s came out as "4.5s3s", wearing the end of the 4.53s that had been there.
  def test_a_shorter_line_covers_the_longer_one_it_replaces
    clock = FakeClock.new
    out = a_terminal
    progress = Progress::Printed.new(out, clock: clock)
    progress.step("lowering")
    clock.pass(1.0)
    progress.of(1, 2, "a routine with a very long name indeed")
    clock.pass(1.0)
    progress.of(2, 2)
    progress.done

    refute_includes out.string.split("\r").last, "name indeed",
                    "a redraw left the end of the line it replaced showing"
  end

  # --- A PACK, AND A GAME'S OWN CODE -----------------------------------------------------------

  # A pack's verbs are mixed into the builder, so `progress` resolves inside one the way `var`
  # and `held` do. Exactly the shape a third party would write.
  ROWS = proc do |rows|
    progress.step "laying out the rows"
    rows.times do |n|
      progress.of n + 1, rows, "row #{n}"
      fill_rect 0, n * 2, 8, 2, :red
    end
  end

  # A game split across plain Ruby objects reaches the same object by being handed it, like any
  # other dependency — the builder's block is not the only place a game's own work happens.
  class Floors
    def initialize(build) = @build = build

    def read(count)
      @build.progress.step "reading the floors"
      count.times { |n| @build.progress.of n + 1, count, "floor #{n}" }
    end
  end

  def teardown
    RubyGBA::Effects.unregister(:paint_the_rows)
  end

  def a_cartridge_built_with(progress)
    RubyGBA.build("PACK", code: "APAK", maker: "01", out: StringIO.new, err: StringIO.new,
                          progress: progress) do
      screen :bitmap
      paint_the_rows 4
      halt
    end
  end

  # The seam is worth having before a pack is slow enough to need it: added afterwards, finding
  # out which pack is the slow one means bisecting a build.
  def test_a_pack_can_say_what_it_is_doing
    RubyGBA::Effects.register(:paint_the_rows, &ROWS)
    out = StringIO.new
    a_cartridge_built_with(Progress.to(out))
    said = phases_in(out).find { |phase| phase.name == "laying out the rows" }

    refute_nil said, "the pack's phase should be among the build's own"
    assert_equal "4 of 4  row 3", said.where
  end

  # ...and what a pack SAYS may never change what it BUILDS. Progress is an observation: a pack
  # that behaved differently when somebody was watching would be a bug that only shows up in the
  # mode nobody tests.
  def test_a_build_that_reports_makes_the_same_cartridge_as_one_that_does_not
    RubyGBA::Effects.register(:paint_the_rows, &ROWS)
    watched = a_cartridge_built_with(Progress.to(StringIO.new))
    quiet = a_cartridge_built_with(Progress.silent)

    assert_equal quiet.buffer, watched.buffer
  end

  # The same seam serves a game's own code, which is the other half of why it is here: a game's
  # block is evaluated on the builder, so reading sixty floors of a map or chewing through a
  # sprite sheet can name itself with no new plumbing.
  def test_a_games_own_code_can_say_what_it_is_doing
    out = StringIO.new
    RubyGBA.build("GAME", code: "AGAM", maker: "01", out: StringIO.new, err: StringIO.new,
                          progress: Progress.to(out)) do
      screen :bitmap
      Floors.new(self).read 3
      halt
    end

    assert_equal "3 of 3  floor 2",
                 phases_in(out).find { |phase| phase.name == "reading the floors" }.where
  end

  # --- THROUGH A REAL BUILD --------------------------------------------------------------------

  def test_a_real_build_names_every_phase_in_order
    assert_equal ["reading the game", "checking the tree", "the guardrails",
                  "measuring the routines", "choosing what goes in the quick memory",
                  "lowering it to machine code", "assembling the cartridge"],
                 phases_of_a_build.map(&:name)
  end

  # The phases that have a real count report one, and the count arrives at its total — a phase
  # that stopped counting half way through would be worse than one that never counted.
  def test_the_counted_phases_count_all_the_way_up
    where = where_each_phase_got_to

    assert_match(/\A(\d+) of \1\b/, where["the guardrails"])
    assert_match(/\A(\d+) of \1\b/, where["choosing what goes in the quick memory"])
  end

  # ...and the two with no count say how far they got the only way they honestly can: nothing
  # knows how many instructions a program comes to until they are emitted.
  def test_the_uncounted_phases_report_the_code_they_have_emitted
    where = where_each_phase_got_to

    assert_match(/\A\d+ bytes\z/, where["lowering it to machine code"])
    assert_match(/\A\d+ bytes\z/, where["measuring the routines"])
  end

  # The guardrails are a list of checks, so the phase can name the one it is on — which is the
  # answer to "why are the guardrails the slow part of my build".
  def test_the_guardrail_phase_names_the_check_it_is_on
    out = StringIO.new
    progress = Progress.to(out)
    progress.step("the guardrails")
    checks = [RubyGBA::IR::Guardrails::Checks::DrawBudget.new,
              RubyGBA::IR::Guardrails::Checks::IwramBudget.new]
    RubyGBA::IR::Guardrails::Validator.new(checks: checks, progress: progress)
                                      .run(RubyGBA::IR::Build.program, autofix: false)
    progress.done

    # ...and named the way a person hears it. The check calls itself `iwram_budget`, which is
    # the console's quick memory said in hardware.
    assert_equal "2 of 2  quick memory budget", phases_in(out).first.where
  end

  # A build that dies half way through a phase still closes its line, so the message explaining
  # why is not printed on top of it.
  def test_a_build_that_stops_closes_the_line_it_had_open
    out = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("BROKE", code: "ABRK", maker: "01", out: StringIO.new, err: StringIO.new,
                             progress: Progress.to(out)) do
        fill_rect 0, 0, 8, 8, :red # drawing with no screen mode: a guardrail error
        halt
      end
    end

    assert_equal "the guardrails", phases_in(out).last.name
  end

  # WHAT THE GUARDRAILS FOUND IS SAID AFTER THE BUILD, not in the middle of it. A paragraph of
  # prose landing between two phases breaks the run of them in half, and the reader loses the
  # shape of the build — so the findings are held and written once every phase has had its say.
  def test_a_warning_is_said_after_the_build_and_not_in_the_middle_of_it
    said = StringIO.new
    RubyGBA.build("NOISY", code: "ANOI", maker: "01", out: StringIO.new, err: said,
                           progress: Progress.to(said)) do
      screen :bitmap
      game_loop { seed 42 } # seeding every frame: a guardrail warning
    end
    phase_lines = said.string.lines.select { |line| line.start_with?("  ") }

    assert_operator said.string.lines.length, :>, phase_lines.length, "expected a warning too"
    assert_equal phase_lines, said.string.lines.first(phase_lines.length),
                 "every phase should be said before the first word of a warning"
  end

  def test_a_game_can_be_asked_to_report_when_it_builds_its_rom
    out = StringIO.new
    game = RubyGBA.game("SPEAK", code: "ASPK", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 8, 8, :red
      halt
    end
    game.build_rom(out: StringIO.new, err: StringIO.new, progress: Progress.to(out))

    assert_match(/reading the game/, out.string)
  end
end

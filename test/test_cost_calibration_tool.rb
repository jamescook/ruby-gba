# frozen_string_literal: true

require "test_helper"

require_relative "../tools/calibration/reductions"
require_relative "../tools/calibration/domain"
require_relative "../tools/calibration/fake_measurer"
require_relative "../tools/calibration/calibrator"
require_relative "../tools/calibration/provenance"
require_relative "../tools/calibration/measured_cartridges"
require_relative "../tools/calibration/weights_fixture"
require_relative "../tools/calibration/cartridges_fixture"

# The calibration tool itself (tools/calibration/), which measures every weight the cost model
# charges. It used to be one flat script welded to the emulator, so none of it could be tested;
# now the emulator sits behind one seam and everything else — the recipes, the arithmetic, the
# file it writes — runs against canned readings.
#
# NOTHING HERE REQUIRES GEMBA. That is the point of the seam and it is worth keeping: these are
# the tests that say the tool's own logic is right, and they must not depend on the thing the
# tool measures. (What the emulator actually reads is checked by test_cost_calibration.rb,
# which is a different question.)
class TestCostCalibrationTool < Minitest::Test
  Calibration = RubyGBA::Calibration
  BendForm = RubyGBA::IR::Backends::GBA::BendForm
  Reductions = Calibration::Reductions
  Domain = Calibration::Domain

  # --- the arithmetic, on known numbers ---

  # The workhorse: two ROMs that differ only in how many of the thing they do, over the
  # difference. Everything they share cancels, which is what leaves the thing's own cost.
  def test_a_marginal_rate_is_the_difference_over_the_spread
    assert_in_delta 0.5, Reductions.marginal(60.0, 10.0, over: 100), 1e-9
  end

  # Dividing by no spread is not a very large rate, it is a bug in the recipe — two ROMs that
  # do the same amount cannot say what one more costs.
  def test_a_marginal_rate_with_no_spread_is_an_error
    assert_raises(ArgumentError) { Reductions.marginal(60.0, 10.0, over: 0) }
  end

  # A compound op's fixed part: its whole cost, minus the parts already priced.
  def test_a_residual_takes_the_priced_parts_out_of_a_whole
    assert_in_delta 2.0, Reductions.residual(10.0, 5.0, 3.0), 1e-9
  end

  # Negative is allowed and is a real signal — it means the parts over-account for the whole, so
  # one of them is measuring something this total does not contain.
  def test_a_residual_may_come_out_negative
    assert_operator Reductions.residual(1.0, 5.0), :<, 0
  end

  # base + slope * n through two points, for a cost with a floor (the software mixer pays to run
  # at all, then a rate per sounding voice).
  def test_a_fit_finds_the_slope_and_the_floor
    slope, base = Reductions.fit(1, 13.0, 8, 34.0)
    assert_in_delta 3.0, slope, 1e-9
    assert_in_delta 10.0, base, 1e-9, "with no voices at all it still costs the floor"
  end

  def test_a_fit_needs_two_different_counts
    assert_raises(ArgumentError) { Reductions.fit(4, 1.0, 4, 2.0) }
  end

  def test_a_ratio_is_how_many_times_faster
    assert_in_delta 2.5, Reductions.ratio(50.0, 20.0), 1e-9
    assert_raises(ArgumentError) { Reductions.ratio(50.0, 0) }
  end

  # --- a weight's domain ---

  def test_a_domain_knows_what_it_covers
    d = Domain.new(varies: :passes, from: 300, to: 900)
    assert d.covers?(300)
    assert d.covers?(900)
    refute d.covers?(4)
    refute d.covers?(2000)
  end

  # Below the floor is the direction that hurts, and the domain says so separately: a marginal
  # rate excludes whatever the thing pays once, and the smaller the count the bigger a share of
  # the cost that is. Above the range, extrapolating a linear rate is usually harmless.
  def test_only_below_the_floor_is_flagged_as_the_dangerous_side
    d = Domain.new(varies: :passes, from: 300, to: 900)
    assert d.under?(4)
    refute d.under?(2000)
  end

  # A weight with no countable regime covers everything — an add costs what an add costs, and no
  # number in a program changes it, so there is nothing to warn about.
  def test_a_weight_with_no_countable_regime_covers_everything
    d = Domain.new(note: "an add")
    assert d.covers?(1)
    assert d.covers?(1_000_000)
    refute d.under?(0)
  end

  # --- the file the tool writes ---

  # The renderer reproduces the COMMITTED fixture byte for byte from the committed weights and
  # domains. A full round trip — the fixture's own contents rendered back into the fixture — so
  # any change to what the tool writes has to be a change somebody meant to make.
  def test_it_renders_the_committed_fixture_exactly
    committed = RubyGBA::IR::CostModel
    rendered = Calibration::WeightsFixture.new(
      weights: committed::MEASURED_WEIGHTS,
      domains: committed::WEIGHT_DOMAINS.transform_values { |d| Domain.new(**d) },
    ).render
    assert_equal File.read(fixture_path), rendered
  end

  def fixture_path
    File.expand_path("../lib/ruby_gba/ir/measured_weights.rb", __dir__)
  end

  # The same round trip for the provenance file beside it.
  def test_it_renders_the_committed_cartridges_exactly
    rendered = Calibration::CartridgesFixture.new(digests: Calibration::MEASURED_CARTRIDGES,
                                                  emulator: Calibration::MEASURED_EMULATOR).render
    assert_equal File.read(cartridges_path), rendered
  end

  def cartridges_path
    File.expand_path("../tools/calibration/measured_cartridges.rb", __dir__)
  end

  # Given domains, it writes them too — and the rendered source has to be valid Ruby that
  # actually defines them, not just text that looks right.
  def test_it_renders_the_domains_when_a_calibration_recorded_them
    source = Calibration::WeightsFixture.new(
      weights: { op_step: 0.5, loop_pass: 0.25 },
      domains: { op_step: Domain.new(note: "an add"),
                 loop_pass: Domain.new(varies: :passes, from: 300, to: 900) },
    ).render

    assert_match(/WEIGHT_DOMAINS = \{/, source)
    assert_match(/loop_pass: \{ varies: :passes, from: 300, to: 900 \}/, source)
    assert_match(/op_step: \{ note: "an add" \}/, source)
  end

  # ...and none at all when nothing recorded any, so a tool that does not measure domains still
  # writes the file it always wrote.
  def test_it_leaves_the_domains_out_when_there_are_none
    refute_match(/WEIGHT_DOMAINS/,
                 Calibration::WeightsFixture.new(weights: { op_step: 0.5 }).render)
  end

  # The rendered source is loaded and its constants read, which is the only assertion that
  # cannot be fooled by a plausible-looking string.
  def test_the_rendered_source_is_loadable_ruby
    source = Calibration::WeightsFixture.new(
      weights: { op_step: 0.5 },
      domains: { op_step: Domain.new(varies: :passes, from: 2, to: 9) },
    ).render
    mod = Module.new
    mod.module_eval(source.sub("module RubyGBA", "module Fixture"))

    assert_in_delta 0.5, mod::Fixture::IR::CostModel::MEASURED_WEIGHTS[:op_step], 1e-9
    assert_equal({ varies: :passes, from: 2, to: 9 },
                 mod::Fixture::IR::CostModel::WEIGHT_DOMAINS[:op_step])
  end

  # --- ARE THE COMMITTED WEIGHTS STILL THIS TREE'S? ---
  #
  # THE FAILURE THIS EXISTS FOR. The weights file says to re-run the calibration after changing
  # the lowering of a priced op, and until now nothing checked that anybody had. A change to the
  # shape of a loop whose body calls a routine left op_div, op_div_fix and blit_start describing
  # a loop shape their benchmarks no longer got; it sat in the file across seven commits and was
  # found by accident, while re-measuring an unrelated weight. The round trip above could not
  # see it — that asks whether the file is what the RENDERER would write given those numbers,
  # which says nothing about whether the numbers are what the tool would measure today. So the
  # one thing that can go stale was the one thing not checked.
  #
  # WHY THIS CAN BE EXACT. The emulator is deterministic, so a cartridge whose bytes have not
  # changed cannot read differently, and one whose bytes HAVE changed may. So the check compares
  # the cartridges rather than the weights: no tolerance to argue about, no false alarm from a
  # refactor that changed no emitted byte, and nothing missed that reaches a benchmarked op. See
  # tools/calibration/provenance.rb for why hashing the source files instead would be worse.
  #
  # It needs no emulator — building a cartridge is not running one — so it belongs in the
  # ordinary suite rather than behind a flag or a commit hook.
  def test_the_weights_were_measured_on_the_cartridges_this_tree_builds
    built = built_cartridges
    recorded = Calibration::MEASURED_CARTRIDGES

    changed = recorded.keys.select { |name| built.key?(name) && built[name] != recorded[name] }
    assert_empty changed, "#{changed.length} of the cartridges the weights were measured on are " \
                          "no longer what this tree builds, so whatever they measured now " \
                          "describes code the build does not emit. Re-run " \
                          "tools/calibrate_cost_model.rb and commit the diff — it prints every " \
                          "weight that moved and by how much."
  end

  # ...and the same question the other two ways round, so that adding or removing a benchmark
  # without re-measuring is caught as loudly as changing one. Each side is named on its own:
  # the interesting thing is the handful that moved, and a list of all hundred and fifty-seven
  # twice over would bury it.
  def test_every_cartridge_the_calibration_builds_is_one_the_weights_were_measured_on
    built = built_cartridges.keys
    recorded = Calibration::MEASURED_CARTRIDGES.keys

    assert_empty built - recorded, "the calibration builds cartridges the committed weights " \
                                   "were never measured on. Re-run tools/calibrate_cost_model.rb."
    assert_empty recorded - built, "the committed weights were measured on cartridges the " \
                                   "calibration no longer builds. Re-run " \
                                   "tools/calibrate_cost_model.rb."
  end

  # THE OTHER HALF, and the cartridges' one blind spot: the emulator itself. Change what it
  # counts and every cartridge is byte-identical while every weight goes stale.
  def test_the_weights_were_measured_on_this_emulator
    assert_equal Calibration::MEASURED_EMULATOR, Calibration::Provenance.emulator_digest,
                 "the emulator's own sources have changed since the weights were measured, and " \
                 "the cartridges cannot see that — they are the same bytes either way. Re-run " \
                 "tools/calibrate_cost_model.rb."
  end

  # Every cartridge this tree's calibration builds, by content. The readings are canned, so no
  # emulator runs; what is exercised is the building.
  def built_cartridges = flat_calibration.last.digests

  # --- the recipes, against canned readings ---

  # Every reading answers the same number, so every marginal rate comes out at zero. Useless as
  # a value and exactly right as a wiring check: it runs every recipe and says they produce the
  # weights the model expects, in the order the fixture wants them.
  #
  # The plain form — nothing canned — is SHARED, because half the tests in this file want the
  # same one and a run builds a hundred and fifty-seven cartridges. It cannot come out
  # differently twice. It also goes through the provenance log, so the cartridge checks above and
  # the recipe checks below are one run rather than two.
  def flat_calibration(default: 1.0, busy: {})
    return self.class.plain_run ||= run_calibration(Calibration::FakeMeasurer.new(default: 1.0)) if
      busy.empty? && default == 1.0

    run_calibration(Calibration::FakeMeasurer.new(busy: busy, default: default))
  end

  def run_calibration(measurer)
    log = Calibration::Provenance::Log.new(measurer)
    [Calibration::Calibrator.new(log).run, log]
  end

  class << self
    attr_accessor :plain_run
  end

  def test_it_produces_exactly_the_weights_the_model_uses_in_the_committed_order
    calibration, = flat_calibration
    assert_equal RubyGBA::IR::CostModel::MEASURED_WEIGHTS.keys, calibration.weights.keys
  end

  # No weight may ship without a record of where it was measured. This is the guard that stops
  # the next weight being added as a bare number with no domain — the same job the conformance
  # fixture does for an unpriced IR kind.
  def test_every_weight_carries_a_domain
    calibration, = flat_calibration
    missing = calibration.weights.keys - calibration.domains.keys
    assert_empty missing, "these weights were measured with no record of where"
    assert(calibration.domains.each_value.all? { |d| d.note || d.varies },
           "a domain with neither a range nor a note says nothing")
  end

  # A real recipe, end to end, on numbers chosen so the answer is known. A loop's pass
  # differences a 900-pass loop against a 300-pass one: 61 minus 1, over the 600 extra passes.
  # Both shapes of loop are measured that way, and the two are told apart by the ROM name —
  # "m" for the counter in memory, "r" for the counter in a register.
  def test_a_recipe_reduces_its_readings_the_way_it_says
    calibration, = flat_calibration(busy: { "lpm900" => 61.0, "lpm300" => 1.0,
                                            "lpr900" => 25.0, "lpr300" => 1.0 })

    assert_in_delta 0.1, calibration.weights[:loop_pass], 1e-9
    assert_in_delta 0.04, calibration.weights[:loop_pass_held], 1e-9
  end

  # A WEIGHT HANDS BACK THE VARIABLE ITS OWN BENCHMARK READ. Every weight is measured on a
  # program that has to get its operands from somewhere — `set :y, x` reads a variable, three
  # instructions of it — and the model charges a variable read where the read is, so a weight
  # that kept its own would make a program pay for the same read twice.
  #
  # Canned readings make that exact. The assignment measures 0.003 a statement and a variable
  # operand measures 0.002, so what op_assign is worth on its own is the difference. Take the
  # subtraction out of the recipe and op_assign comes back 0.003 and this says so.
  # ...and a DRAWING weight hands back as many as its benchmark read, which for a blit is two:
  # the x and the y it is drawn at. Left in, every sprite a game moves would pay for reaching
  # its own position twice — once inside the blit's weight and once for the position it holds.
  def test_a_weight_whose_benchmark_read_a_variable_hands_that_read_back
    calibration, = flat_calibration(busy: { "assign2" => 1.0, "assign8" => 10.0,    # over 500 x 6 ops
                                            "varop2" => 1.0, "varop6" => 3.4,       # over 300 x 4 ops
                                            "bltred4x8x3" => 1.02 })                # over 2 x 2 blits

    assert_in_delta 0.002, calibration.weights[:var_operand], 1e-9
    assert_in_delta 0.001, calibration.weights[:op_assign], 1e-9,
                    "op_assign is what the statement costs once its operand's read is out of it"
    assert_in_delta 0.001, calibration.weights[:blit_start], 1e-9,
                    "a blit measures 0.005 before its rows, two of which are reaching its position"
  end

  # A BACKGROUND'S SCROLL IS MEASURED OVER BACKGROUNDS AND NOT OVER SCROLL CALLS, which is the
  # whole recipe rather than a detail of it. The write that moves a background's window is made
  # once a frame however often the game asked for it — that is what stops scrolling tearing — so
  # a sweep over calls measures the loop around them and the statements in it, and names the
  # answer after the writes. It read a scrolling background at twice its cost.
  #
  # Canned, four scrolling backgrounds cost 0.015 more than one, so one background's scroll is
  # 0.005 — of which two are the variables the window's position is kept in, handed back the way
  # every weight hands back what its own benchmark read.
  def test_a_backgrounds_scroll_is_measured_over_backgrounds_and_hands_its_reads_back
    calibration, = flat_calibration(busy: { "varop2" => 1.0, "varop6" => 3.4,     # var_operand 0.002
                                            "scr1" => 1.0, "scr4" => 1.015 })     # over 3 backgrounds

    assert_in_delta 0.001, calibration.weights[:scroll_write], 1e-9,
                    "0.005 a background, less the two variables it reads to know where it sits"

    domain = calibration.domains[:scroll_write]
    assert_equal :scrolling_backgrounds, domain.varies,
                 "the sweep is over how many backgrounds scroll, not over how often one is scrolled"
    assert_equal [1, 4], [domain.from, domain.to],
                 "and one to four is the whole range there is — four backgrounds is as many as " \
                 "the display has, and a game that scrolls none pays nothing"
  end

  # ...AND THE TWO CARTRIDGES REALLY DO DIFFER BY THE WRITES ALONE, which the test above cannot
  # see: a canned reading is keyed by name and never opens the cartridge it is handed. So this
  # one opens them. Each frame is the wait for the screen and one write per scrolling background
  # — no loop, and no statement of the program's own — and that is what makes their difference
  # the writes rather than whatever was arranged around them.
  #
  # This is the guard the weight was missing. A sweep over how often a game SCROLLS builds two
  # frames that differ by a loop and two statements a pass, both of which the model already
  # prices where they are written, and calls the answer a scroll.
  def test_the_two_scroll_cartridges_differ_by_the_writes_and_nothing_else
    catcher = RomCatcher.new(default: 1.0)
    bench = Calibration::Benchmarks.new(catcher)
    bench.scroll_busy(1)
    bench.scroll_busy(4)

    assert_equal({ "scr1" => %i[wait_vblank scroll_background],
                   "scr4" => %i[wait_vblank] + ([:scroll_background] * 4) },
                 catcher.roms.transform_values { |rom| frame_body(rom) },
                 "each frame is the wait and one write per scrolling background, and nothing more")
  end

  # KEEPING A SPRITE OUT OF A PLACED FADE, measured against the SAME sprites with no fade over
  # them. Canned, 64 sprites cost 0.63 more once a fade is placed above them, over the 63 that
  # are kept — so one window is 0.01.
  #
  # The sweep is what makes the number mean anything: both cartridges present 64 sprites, so
  # the sprite writes cancel and what is left is the windows. Differenced against a smaller
  # count instead, this would be measuring the sprites again and calling the answer a window.
  def test_keeping_a_sprite_out_of_a_fade_is_measured_against_the_same_sprites_unfaded
    calibration, = flat_calibration(busy: { "objup64" => 1.0, "objupk64" => 1.63 })

    assert_in_delta 0.01, calibration.weights[:obj_window_write], 1e-9

    domain = calibration.domains[:obj_window_write]
    assert_equal :kept_sprites, domain.varies
    assert_equal [63, 63], [domain.from, domain.to],
                 "64 sprites and their 63 windows is the ceiling — each kept sprite takes a " \
                 "second slot in the table of 128"
  end

  # ...AND THE TWO CARTRIDGES REALLY DO DIFFER BY THE WINDOWS ALONE, which the canned reading
  # above cannot see. Both frames wait for the screen and present the same sprites; the fade is
  # placed once, outside the loop, so the frame under measurement holds the windows and nothing
  # else. One sprite stays below the line in the fading ROM, because a fade that keeps EVERY
  # sprite has nothing left to fade and makes no window at all.
  def test_the_two_kept_sprite_cartridges_differ_by_the_windows_alone
    catcher = RomCatcher.new(default: 1.0)
    bench = Calibration::Benchmarks.new(catcher)
    n = Calibration::Benchmarks::KEPT_SPRITES
    bench.sprites_busy(n)
    bench.sprites_busy(n, kept: true)
    plain, kept = catcher.roms.values_at("objup#{n}", "objupk#{n}")

    assert_equal [frame_body(plain)], [frame_body(kept)],
                 "each frame waits for the screen and presents its sprites, and nothing else"
    assert_equal [n, n], [presented(plain), presented(kept)], "the same sprites on both sides"
    assert_nil kept_sprites(plain), "nothing is kept out of a fade this cartridge does not place"
    assert_equal n - 1, kept_sprites(kept)
  end

  # A BEND FED BY THE COPIER is measured over HOW MANY LAYERS BEND, which is the thing the
  # model assumes — it charges a table per bending layer. Canned, three bending layers cost
  # 3.2 more than one, over the 320 rows of table the extra two add, so a row is 0.01.
  def test_a_copied_bend_is_measured_over_the_layers_that_bend
    calibration, = flat_calibration(busy: { "bendc1" => 1.0, "bendc3" => 4.2 })

    assert_in_delta 0.01, calibration.weights[:bend_row_copied], 1e-9

    domain = calibration.domains[:bend_row_copied]
    assert_equal :bending_layers, domain.varies
    assert_equal [1, 3], [domain.from, domain.to],
                 "three is as many layers as there are engines to feed them — the fourth " \
                 "copier is the general one every fill and upload uses"
  end

  # AN INTERRUPT'S OWN COST IS READ OFF TWO BLOCKS AND EXTENDED BACK TO NONE, which is the one
  # recipe here that is not a plain difference. A block that does nothing is exactly the block
  # the build hands to a copying engine, so the cartridge that would measure a bare interrupt
  # cannot be built; two blocks that do 1 and 5 statements can, and the line through them says
  # what is left with none.
  #
  # Canned: 1 statement costs 1.4 over the un-bending cartridge and 5 cost 3.0, so a statement
  # is 0.4 and the interrupt itself is 1.0 — over the 228 lines the display counts.
  def test_the_bare_interrupt_is_fitted_back_from_two_blocks_that_do_something
    calibration, = flat_calibration(busy: { "bend0" => 1.0, "bend1" => 2.4, "bend5" => 4.0 })

    assert_in_delta 1.0 / 228, calibration.weights[:bend_line], 1e-9,
                    "the block's own statements are fitted out, leaving the interrupt"

    domain = calibration.domains[:bend_line]
    assert_equal [228, 228], [domain.from, domain.to],
                 "a program cannot ask the display to draw a different number of lines"
  end

  # ...AND THE BENDING CARTRIDGES REALLY ARE WHAT THE TWO RECIPES SAY, which the canned
  # readings above cannot see. Every frame is the wait for the screen and nothing else: a bend
  # is a standing declaration, so whichever way it is lowered, none of it is a statement in the
  # frame the program wrote.
  def test_the_bending_cartridges_are_what_the_two_recipes_take_them_for
    catcher = RomCatcher.new(default: 1.0)
    bench = Calibration::Benchmarks.new(catcher)
    bench.bend_busy(false)
    Calibration::Benchmarks::BEND_STEPS.each { |n| bench.bend_busy(true, steps: n) }
    Calibration::Benchmarks::COPIED_BENDS.each { |n| bench.bend_copied_busy(n) }
    one, five, few, many = catcher.roms.values_at("bend1", "bend5", "bendc1", "bendc3")

    assert_equal [%i[wait_vblank]] * 5, catcher.roms.each_value.map { |rom| frame_body(rom) },
                 "each frame waits for the screen, and a bend is nowhere in it"
    [one, five].each do |rom|
      refute BendForm.copier?(rom.source_program), "a block that sets a variable is answered per line"
    end
    assert_equal [1, 5], [one, five].map { |rom| block_statements(rom) },
                 "and the pair the interrupt is fitted from differ by their blocks alone"

    [few, many].each { |rom| assert BendForm.copier?(rom.source_program), "a block of one number is copied" }
    assert_equal [1, 3], [few, many].map { |rom| bending_layers(rom) }
    assert_equal [3, 3], [few, many].map { |rom| backgrounds(rom) },
                 "both sides show three backgrounds, so what is differenced is the tables and " \
                 "not the display's own work"
  end

  # How many statements this cartridge's bend records beside the offset it works out, how many
  # of its layers bend, and how many backgrounds it shows at all.
  def block_statements(rom)
    rom.source_program.walk.select { |node| node.kind == :scroll_rows }.sum { |n| n.children.length }
  end

  def bending_layers(rom) = rom.source_program.walk.count { |node| node.kind == :scroll_rows }
  def backgrounds(rom) = rom.source_program.walk.count { |node| node.kind == :background }

  # How many sprites this cartridge's frame presents, and how many of them a placed fade has
  # to be held off one at a time.
  def presented(rom)
    rom.source_program.walk.select { |node| node.kind == :present_objects }.sum { |n| n.names.length }
  end

  def kept_sprites(rom)
    rom.cost_model.kept_sprites_verdict(rom.source_program)&.sprites
  end

  # A canned measurer that also KEEPS the cartridges it was handed, so a test can ask what a
  # benchmark's two ROMs differ by rather than only what it was told they cost.
  class RomCatcher < Calibration::FakeMeasurer
    attr_reader :roms

    def initialize(**kwargs)
      super
      @roms = {}
    end

    def busy(name, rom)
      @roms[name] = rom
      super
    end
  end

  # What one frame of this cartridge does, as the kinds of its statements in order.
  def frame_body(rom)
    rom.source_program.walk.find { |node| node.kind == :loop }.children.map(&:kind)
  end

  # And the domain it records is the sweep it actually ran, not a number typed beside it.
  def test_the_domain_records_the_sweep_the_recipe_ran
    calibration, = flat_calibration
    domain = calibration.domains[:overlap_pixel]
    assert_equal :overlap_pixels, domain.varies
    assert_equal 8 * 8, domain.from
    assert_equal 16 * 16, domain.to
  end

  # A weight with no countable regime records none. A loop is the worked example: its rate per
  # pass and the cost of entering it are measured apart, so what is left in the rate holds at
  # one pass as surely as at nine hundred and there is no range to record.
  def test_a_weight_with_no_regime_records_no_range
    calibration, = flat_calibration

    assert_nil calibration.domains[:loop_pass].varies
    assert calibration.domains[:loop_pass].note, "it still says what it is"
    assert_nil calibration.domains[:loop_start].varies
  end

  # A reading nobody canned raises rather than answering zero. A test that quietly measured
  # nothing would pass while proving nothing.
  def test_an_unknown_reading_is_an_error_not_a_zero
    fake = Calibration::FakeMeasurer.new(busy: { "lp300" => 1.0 })
    assert_raises(KeyError) { Calibration::Calibrator.new(fake).run }
  end
end

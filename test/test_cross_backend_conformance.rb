# frozen_string_literal: true

require "test_helper"

require_relative "conformance_fixture"

# The coverage guard (gba-8sq): run ONE kitchen-sink IR program through every
# backend. If a backend doesn't implement a feature the fixture uses, it hits its
# "unsupported" branch and this test fails — so a backend can't silently lag
# behind another. Complementary to the differential test (gba-cbw), which checks
# the backends AGREE on output; this one checks they all COVER every feature.
class TestCrossBackendConformance < Minitest::Test
  Node = RubyGBA::IR::Node
  ROMValidator = RubyGBA::ROMValidator

  # ---- the fixture actually covers everything (maintenance guard) ----

  def test_fixture_touches_every_ir_node_kind
    used = ConformanceFixture.program.walk.map(&:kind).uniq.to_set
    expected = Node::CATEGORY.keys.to_set
    missing = expected - used

    assert_empty missing,
                 "the conformance fixture is missing IR kinds #{missing.to_a.inspect} — " \
                 "add them to test/conformance_fixture.rb (see its maintenance note)"
  end

  def test_fixture_exercises_every_binary_operator
    ops = ConformanceFixture.program.walk
                            .select { |n| n.kind == :binop }.map { |n| n[:op] }.uniq.to_set
    missing = ConformanceFixture::OPERATORS.to_set - ops

    assert_empty missing,
                 "the conformance fixture is missing binops #{missing.to_a.inspect} — " \
                 "add them to test/conformance_fixture.rb"
  end

  # ---- every backend handles every feature the fixture uses ----

  def test_ruby_interpreter_runs_the_whole_fixture
    # Any feature the interpreter can't execute raises ProgramError from its
    # "cannot execute ..." branch and fails here. Reaching the terminal halt
    # (not the step budget) proves the whole top-to-bottom flow ran.
    interp = Reference.new.run(ConformanceFixture.program, max_steps: 10_000)

    refute interp.stopped_at_budget?,
           "the fixture should sync-then-halt cleanly, not run out the step budget"
  end

  def test_gba_backend_lowers_the_whole_fixture_to_a_clean_rom
    # A feature the GBA backend can't lower raises LoweringError; a structurally
    # bad ROM makes ROM.assemble (which validates the image) raise ROMError.
    # Neither may happen.
    code = GBA.new.lower(ConformanceFixture.program)
    rom = ROM.assemble(code, title: "CONFORM", code: "BCNF", maker: "01")

    assert ROMValidator.check(rom).ok?, "the lowered fixture must be a valid ROM"
  end

  # ---- the one hardware-only exception, pinned explicitly ----

  def test_raw_is_hardware_only_the_interpreter_refuses_it
    # `raw` is native bytes — the portable interpreter has no CPU to run them, so
    # reaching one must raise, not silently pass. (In the fixture it's kept in an
    # uncalled func, so it's never reached there.)
    err = assert_raises(Reference::ProgramError) do
      Reference.new.run(RubyGBA::IR::Build.program(RubyGBA::IR::Build.raw("\x00\x00\x00\x00".b)))
    end
    assert_match(/cannot execute|raw/i, err.message)
  end

  def test_raw_lowers_on_the_gba_backend
    nop = [0xE1A00000].pack("V")
    code = GBA.new.lower(RubyGBA::IR::Build.program(
      RubyGBA::IR::Build.screen(:bitmap),
      RubyGBA::IR::Build.raw(nop),
      RubyGBA::IR::Build.halt,
    ))
    assert_includes code, nop, "the GBA backend appends raw bytes verbatim"
  end

  def test_hardware_only_kinds_are_the_only_ones_the_interpreter_skips
    # Guard the exemption itself: the hardware-only kinds today are raw and
    # read_scanline. This flows from the portability tags (via
    # ConformanceFixture::HARDWARE_ONLY_KINDS), so a newly tagged hardware-only kind
    # trips this and the fixture's reasoning.
    assert_equal %i[raw read_scanline].to_set, ConformanceFixture::HARDWARE_ONLY_KINDS.to_set
  end
end

# frozen_string_literal: true

require "test_helper"

require "conformance_fixture"

# The coverage guard: run ONE kitchen-sink IR program through every
# backend. If a backend doesn't implement a feature the fixture uses, it hits its
# "unsupported" branch and this test fails — so a backend can't silently lag
# behind another. Complementary to the differential test, which checks
# the backends AGREE on output; this one checks they all COVER every feature.
#
# This file holds the fixture to covering everything. The fixture played on the lowering under
# test is in test/console/gba/vblank/ir/test_cross_backend_conformance_on_the_advance.rb (it plays
# a recording in a song, which a Game Boy Color cannot), the interpreter running it in
# test/interpreter/vblank/ir/test_cross_backend_conformance_interpreter.rb, and the Advance's
# lowering of it in test/lowering/gba/vblank/ir/test_cross_backend_conformance_cartridge.rb.
class TestCrossBackendConformance < Minitest::Test
  # ---- the fixture actually covers everything (maintenance guard) ----

  def test_fixture_touches_every_ir_node_kind
    used = ConformanceFixture.program.walk.map(&:kind).uniq.to_set
    expected = VBlank::IR::Nodes.by_kind.keys.to_set
    missing = expected - used

    assert_empty missing,
                 "the conformance fixture is missing IR kinds #{missing.to_a.inspect} — " \
                 "add them to test/conformance_fixture.rb (see its maintenance note)"
  end

  def test_fixture_exercises_every_binary_operator
    ops = ConformanceFixture.program.walk
                            .select { |n| n.kind == :binop }.map { |n| n.op }.uniq.to_set
    missing = ConformanceFixture::OPERATORS.to_set - ops

    assert_empty missing,
                 "the conformance fixture is missing binops #{missing.to_a.inspect} — " \
                 "add them to test/conformance_fixture.rb"
  end

  def test_hardware_only_kinds_are_the_only_ones_the_interpreter_skips
    # Guard the exemption itself: the hardware-only kinds today are raw and
    # read_scanline. This flows from the portability tags (via
    # ConformanceFixture::HARDWARE_ONLY_KINDS), so a newly tagged hardware-only kind
    # trips this and the fixture's reasoning.
    assert_equal %i[raw read_scanline].to_set, ConformanceFixture::HARDWARE_ONLY_KINDS.to_set
  end
end

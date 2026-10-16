# frozen_string_literal: true

require "test_helper"

# Portability tiers: every IR node kind is tagged portable or hardware-only, so a
# preflight/lint can tell a program apart that runs anywhere from one pinned to
# the GBA. Each kind says its tier where it is declared; these tests check the tiers
# and exercise the queries a lint consumes.
class TestIRPortability < Minitest::Test
  include RubyGBA::IR::Build

  Node = RubyGBA::IR::Node
  Portability = RubyGBA::IR::Portability

  # ---- every kind says its tier where it is declared ----

  def test_every_kind_has_a_known_tier
    RubyGBA::IR::Nodes.by_kind.each do |kind, type|
      tier = type.tier
      assert_includes Portability::TIERS, tier, "#{kind} has an unknown tier #{tier.inspect}"
    end
  end

  # ---- the classification today ----

  def test_the_hardware_only_kinds
    # Two things only a real console can do: append opaque native bytes (raw), and
    # read the live scanline (read_scanline). Everything else is portable.
    assert_equal %i[raw read_scanline].sort, Portability.hardware_only_kinds.sort
  end

  def test_ordinary_ops_are_portable
    assert Portability.portable?(:set)
    assert Portability.portable?(:draw_rect_at)
    assert Portability.portable?(:beep)
    assert Portability.portable?(:binop)
  end

  def test_raw_is_hardware_only
    assert Portability.hardware_only?(:raw)
    refute Portability.portable?(:raw)
  end

  # ---- the query accepts a kind or a node ----

  def test_of_accepts_a_node
    assert_equal :portable, Portability.of(set(:x, 1))
    assert_equal :hardware_only, Portability.of(raw("\x00\x00\x00\x00".b))
  end

  def test_a_name_that_is_no_kind_raises
    err = assert_raises(ArgumentError) { Portability.of(:frobnicate) }
    assert_match(/no IR kind :frobnicate/, err.message)
  end

  # ---- a program's tier is the floor over its nodes ----

  def test_an_all_portable_program_is_portable
    prog = program(screen(:bitmap), set(:x, 1), draw_rect_at(var_ref(:x), int(0), 4, 4, :red), halt)
    assert_equal :portable, Portability.program_tier(prog)
    assert_empty Portability.hardware_only_kinds_in(prog)
  end

  def test_one_hardware_only_node_makes_the_whole_program_hardware_only
    # Even tucked in an uncalled func, a raw node drags the program's tier down —
    # the floor is over every node in the tree, reached or not.
    prog = program(
      screen(:bitmap),
      func(:never_called, raw("\x00\x00\x00\x00".b)),
      halt,
    )
    assert_equal :hardware_only, Portability.program_tier(prog)
    assert_equal %i[raw], Portability.hardware_only_kinds_in(prog)
  end
end

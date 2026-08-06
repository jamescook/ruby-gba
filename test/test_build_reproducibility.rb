# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "../examples/pong"
require_relative "../examples/pacman"
require_relative "../examples/snake_buffered"

# Building one program twice must give the same bytes.
#
# Every comparison `rake profile` makes rests on this, and so does anything that
# would ever cache or bisect a build. It matters most that it fails LOUDLY, because
# the alternative is a tool that quietly reports differences that were never there.
#
# WHAT ONE PROCESS CAN PIN, which is what this file does: a name derived from
# object identity, a counter that should reset per build and doesn't, and — the one
# this project actually owns — global state left over from an earlier build. The
# effect-pack registry and the guardrail registry are global and mutable, so a
# program that uses no pack has to lower to the same bytes before and after some
# other pack registers itself.
#
# WHAT IT CANNOT PIN, deliberately: anything that varies between processes rather
# than within one — filesystem order from a glob, per-process string hashing. Two
# builds in one process would agree on those however wrong they were. That half is
# covered by `rake profile`, which builds every example in a separate process
# against two copies of the library every time it runs, and would report the
# difference as a delta.
#
# Not Hash iteration order, which is a real trap in other languages and not one
# here: Ruby Hashes and Sets iterate in insertion order by specification.
#
# A few programs rather than the whole examples/ directory — these three between
# them cover a direct-color screen with sound and scenes, a tiled screen with
# hardware sprites and art sliced out of an image file, and double buffering (which
# builds a palette, where an ordering mistake would show). Building every example
# twice was measured at several seconds and gets slower with each one added, while
# finding nothing these don't.
class TestBuildReproducibility < Minitest::Test
  Effects = RubyGBA::Effects
  Guardrails = RubyGBA::IR::Guardrails
  GBA = RubyGBA::IR::Backends::GBA

  # What each one is here to cover, so a future reader knows what would be lost by
  # dropping it.
  SUBJECTS = {
    "a direct-color screen, sound and scenes" => -> { Pong },
    "a tiled screen, hardware sprites and art sliced from an image file" => -> { Pacman::GAME },
    "double buffering, which builds a palette" => -> { BufferedSnake::GAME },
  }.freeze

  def setup
    @already_registered = Guardrails.registered_checks
  end

  def teardown
    Effects.clear_registered!
    Guardrails.clear_registered!
    @already_registered.each { |check| Guardrails.register(check) }
  end

  # The whole pipeline, twice: run the DSL block again, lower the tree again.
  def build(game) = GBA.new.lower(game.program)

  # When these fail, the cause is nearly always one of three things, so say so
  # rather than printing two multi-kilobyte strings that differ at byte 4,912.
  WHAT_TO_LOOK_AT =
    "The same program lowered to different bytes the second time. Look for: a name " \
    "built from object identity, a counter that is not reset for each build, or state " \
    "left in a global registry by the build before"

  def assert_same_build(game, what)
    assert_same_bytes build(game), build(game), what
  end

  # Never assert_equal two ROMs: they are tens of kilobytes of binary, and minitest
  # would print both in full to tell you they differ somewhere. Say where instead.
  def assert_same_bytes(first, second, what)
    assert_equal first.bytesize, second.bytesize,
                 "#{what}: the second build came out a different size. #{WHAT_TO_LOOK_AT}"

    at = first_difference(first, second)
    assert_nil at, "#{what}: both builds are #{first.bytesize} bytes but they differ " \
                   "from byte #{at}. #{WHAT_TO_LOOK_AT}"
  end

  # Where two builds first disagree, or nil if they never do.
  def first_difference(first, second)
    return nil if first == second

    (0...first.bytesize).find { |i| first.getbyte(i) != second.getbyte(i) }
  end

  SUBJECTS.each do |what, handle|
    define_method(:"test_#{what.gsub(/[^a-z]+/, '_')}_builds_the_same_twice") do
      assert_same_build handle.call, what
    end
  end

  # Lowering the SAME tree twice, rather than rebuilding it — so a failure here says
  # the backend is what carries state between builds, and a failure only in the
  # tests above says it is the DSL.
  def test_lowering_one_tree_twice_gives_the_same_bytes
    tree = Pacman::GAME.program

    assert_same_bytes GBA.new.lower(tree), GBA.new.lower(tree), "one tree lowered twice"
  end

  # A pack that draws, so registering it really does run new code through the
  # builder rather than just defining a method somewhere.
  module Corners
    def paint_corner(color)
      fill_rect 0, 0, 20, 20, color
    end
  end

  # The case this project owns. The registry is global, so a game built after
  # someone loads an effect pack must come out exactly as it did before — a pack
  # that a program never calls must cost it nothing at all.
  def test_a_pack_registering_does_not_change_a_program_that_never_uses_it
    before = build(Pong)
    RubyGBA.register_effects(Corners)
    after = build(Pong)

    assert_same_bytes before, after,
                      "a program that never calls the pack, built after the pack registered"
  end

  # And the pack has to be genuinely loaded for the test above to mean anything.
  def test_the_pack_really_did_register
    RubyGBA.register_effects(Corners)

    assert_includes Effects.verbs, :paint_corner
  end
end

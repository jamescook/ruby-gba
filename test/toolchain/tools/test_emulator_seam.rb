# frozen_string_literal: true

require_relative "../../test_helper"

# The seam between this library and the emulator it verifies ROMs on: which build gets loaded,
# and what a reader is told when none can be.
#
# Both halves are about the same fact — a compiled extension belongs to the Ruby that built it
# and to no other. Getting that wrong is quiet in a way most failures are not: the binary is
# there, every timestamp says it is current, and the only thing that knows is the loader.
class TestEmulatorSeam < Minitest::Test
  Emulator = RubyGBA::Diagnostics::Emulator

  # The backend is loaded here rather than by a require at the top of the file, because going
  # through the seam is the thing under test.
  def setup = Emulator.load!

  # --- which build ------------------------------------------------------------------------------

  # The Ruby down to its patch release, because that is the granularity that matters: a version
  # manager keeps each release under a prefix of its own, and the extension names that prefix's
  # library. Two releases of one series are two different builds.
  def test_a_build_is_named_after_the_ruby_that_made_it
    assert_includes RubyGBAEmulator::BUILT_FOR, RUBY_VERSION
    assert_includes RubyGBAEmulator::BUILT_FOR, RbConfig::CONFIG["arch"]
  end

  # A checkout's build goes under that name, so a Ruby that has not built the extension finds an
  # empty path rather than a binary it will refuse. Says nothing about a gem install: RubyGems
  # builds one per ABI and puts it on a load path of its own.
  def test_a_checkout_loads_the_build_made_for_this_ruby
    checkout = File.expand_path("../../../ruby-gba-emulator/lib", __dir__)
    loaded = $LOADED_FEATURES.grep(/ruby_gba_emulator_ext\./).grep(/\A#{Regexp.escape(checkout)}/)

    assert(loaded.all? { |path| path.include?(RubyGBAEmulator::BUILT_FOR) },
           "a build in the checkout has to be under the Ruby that made it: #{loaded}")
  end

  # --- what a reader is told ---------------------------------------------------------------------

  # THE ERROR SETTLES IT, NOT THE BUNDLE. A tool run as a plain `ruby` subprocess has no bundle
  # at all, so "is the gem in your bundle" answers no however the load really failed — and the
  # advice that follows tells somebody to add a Gemfile block they already have. What the loader
  # said is the thing that knows.
  def test_a_build_from_another_ruby_is_told_to_rebuild
    said = advice("linked to incompatible /rubies/4.0.5/lib/libruby.4.0.dylib - ext.bundle",
                  bundled: false)

    assert_includes said, "rake compile_emulator"
    refute_includes said, "Gemfile", "the bundle is not what is wrong"
  end

  def test_a_library_the_loader_cannot_find_is_told_the_same
    said = advice("libruby.so.4.0: cannot open shared object file", bundled: false)

    assert_includes said, "rake compile_emulator"
    refute_includes said, "Gemfile"
  end

  # The two cases underneath are untouched. A `path:` entry resolves the gem and builds nothing,
  # so that one is told to build...
  def test_a_gem_in_the_bundle_with_nothing_built_is_told_to_build
    said = advice("cannot load such file -- ruby_gba_emulator/ruby_gba_emulator_ext", bundled: true)

    assert_includes said, "rake compile_emulator"
    refute_includes said, "Gemfile"
  end

  # ...and somebody with none of this installed is told how to get it, which is the usual case
  # and a reader building a game rather than repairing a checkout.
  def test_an_emulator_that_is_not_there_at_all_is_told_how_to_get_one
    said = advice("cannot load such file -- ruby_gba_emulator", bundled: false)

    assert_includes said, "Gemfile"
    refute_includes said, "different Ruby"
  end

  private

  def advice(detail, bundled:) = Emulator.send(:missing_advice, detail, bundled: bundled)
end
